module Neodoc where

import Prelude
import Data.Array as A
import Data.Maybe (Maybe(..), maybe)
import Data.Either (Either (..), either)
import Data.StrMap (StrMap)
import Data.String as String
import Data.Char as Char
import Data.StrMap as StrMap
import Data.List (List(..), (:), many, toUnfoldable, concat, fromFoldable, catMaybes)
import Data.NonEmpty (NonEmpty, (:|))
import Data.Traversable (for)
import Data.Pretty (class Pretty, pretty)
import Data.Foreign (Foreign)
import Data.Foreign.Class as F
import Data.Foreign as F
import Data.Foldable (any, intercalate)
import Data.String.Yarn (lines, unlines)
import Control.Monad.Eff.Exception (Error, throwException, EXCEPTION)
import Control.Monad.Eff.Console (CONSOLE)
import Control.Monad.Eff.Console as Console
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff (Eff)
import Node.Process (PROCESS)
import Node.Process as Process
import Node.FS (FS)
import Text.Wrap (dedent)

import Neodoc.Spec
import Neodoc.Options
import Neodoc.Data.UsageLayout
import Neodoc.Data.LayoutConversion
import Neodoc.Data.EmptyableLayout
import Neodoc.Error.Class (capture) as Error
import Neodoc.Error as Error
import Neodoc.Error (NeodocError)
import Neodoc.Scanner as Scanner
import Neodoc.Spec.Parser as Spec
import Neodoc.Spec.Lexer as Lexer
import Neodoc.Solve as Solver
import Neodoc.Value (Value(..))
import Neodoc.ArgParser as ArgParser
import Neodoc.ArgParser (ArgParseResult(..))
import Neodoc.Evaluate as Evaluate
import Neodoc.Data.SolvedLayout

_DEVELOPER_ERROR_MESSAGE :: String
_DEVELOPER_ERROR_MESSAGE = dedent """
  This is an error with the program itself and not your fault.
  Please bring this to the program author's attention.
"""

type NeodocEff e = (
    process :: PROCESS
  , err     :: EXCEPTION
  , console :: CONSOLE
  , fs      :: FS
  | e
)

data Output
  = VersionOutput String
  | ParseOutput (StrMap Value)
  | HelpOutput String

runJS
  :: ∀ eff
   . Either (Spec UsageLayout) String
  -> NeodocOptions
  -> Eff (NeodocEff eff) Foreign
runJS input opts = do
  x <- run input opts
  pure case x of
    (ParseOutput   x) -> F.toForeign x
    (HelpOutput    x) -> F.toForeign x
    (VersionOutput x) -> F.toForeign x

run
  :: ∀ eff
   . Either (Spec UsageLayout) String
  -> NeodocOptions
  -> Eff (NeodocEff eff) Output
run input (NeodocOptions opts) = do
  argv <- maybe (A.drop 2 <$> Process.argv) pure opts.argv
  env  <- maybe Process.getEnv              pure opts.env

  -- 1. obtain a spec, either by using the provided spec or by parsing a fresh
  --    one.
  inputSpec@(Spec { program, helpText }) <- runNeodocError Nothing do
    either pure parseHelptext input

  -- 2. solve the spec
  spec@(Spec { descriptions }) <- runNeodocError Nothing do
    Error.capture do
      Solver.solve opts inputSpec

  -- 3. run the arg parser agains the spec and user input
  output <- runNeodocError (Just program) do
    ArgParseResult mBranch vs <- do
      Error.capture do
        ArgParser.run spec opts env argv
    pure $ Evaluate.reduce env descriptions mBranch vs

  if output `has` opts.helpFlags then
    if opts.dontExit
        then pure (HelpOutput helpText)
        else Console.log helpText *> Process.exit 0
    else
      if output `has` opts.versionFlags then do
        mVer <- maybe readPkgVersion (pure <<< pure) opts.version
        case mVer of
          Just ver ->
            if opts.dontExit
                then pure (VersionOutput ver)
                else Console.log ver *> Process.exit 0
          Nothing -> runNeodocError (Just program) (Left Error.VersionMissingError)
    else pure (ParseOutput output)

  where
  runNeodocError
    :: ∀ eff a
     . Maybe String
    -> Either NeodocError a
    -> Eff (NeodocEff eff) a
  runNeodocError mProg x = case x of
    Left err ->
      let msg = renderNeodocError mProg err
       in if opts.dontExit
            then throwException $ jsError msg {}
            else
              let msg' = if Error.isDeveloperError err
                            then msg <> "\n" <> _DEVELOPER_ERROR_MESSAGE
                            else msg
              in Console.error msg' *> Process.exit 1
    Right x -> pure x

  has x = any \s ->
              maybe false (case _ of
                            IntValue  0     -> false
                            BoolValue false -> false
                            ArrayValue []   -> false
                            _               -> true
                            ) (StrMap.lookup s x)
  readPkgVersion = readPkgVersionImpl Just Nothing

parseHelptextJS
  :: ∀ eff
   . String
  -> Eff (NeodocEff eff) Foreign
parseHelptextJS help = do
  case parseHelptext help of
    Left e ->
      let msg = renderNeodocError Nothing e
       in throwException $ jsError msg {}
    Right (Spec spec) ->

      -- make the layout emptyable, since there are no guarantees in JS.
      -- when we run from an existing spec, we must convert back no non-
      -- emptyable using `Neodoc.Data.LayoutConversion`
      -- XXX: Move this into layout conversion!!!
      let layouts = do
            catMaybes $ fromFoldable $ spec.layouts <#> \toplevel ->
              let branches' = catMaybes $ toplevel <#> \branch ->
                    case toEmptyableBranch branch of
                      Nil  -> Nothing
                      x : xs -> Just $ x:| xs
                in case branches' of
                    Nil -> Nothing
                    xs  -> Just xs
          layouts' = case layouts of
                      Nil    -> Nil :| Nil
                      x : xs ->   x :| xs
       in pure $ F.write $ Spec $ spec { layouts = layouts' }


parseHelptext
  :: String
  -> Either NeodocError (Spec UsageLayout)
parseHelptext help = do
  -- scan the input text
  { originalUsage, usage, options } <- Error.capture do
    Scanner.scan $ dedent help

  -- lex/parse the usage section
  { program, layouts } <- do
    toks <- Error.capture $ Lexer.lexUsage usage
    Error.capture $ Spec.parseUsage toks

  -- lex/parse the description section(s)
  descriptions <- concat <$> for options \description -> do
    toks <- Error.capture $ Lexer.lexDescs description
    Error.capture $ Spec.parseDescription toks

  pure $ Spec { program
              , layouts
              , descriptions
              , helpText: help
              , shortHelp: originalUsage
              }

renderNeodocError :: Maybe String -> NeodocError -> String
renderNeodocError (Just prog) (Error.ArgParserError msg) =
  -- de-capitalize the error message after the colon
  case String.uncons msg of
        Nothing -> msg
        Just { head, tail } ->
          let msg' = String.singleton (Char.toLower head) <> tail
          in prog <> ": " <> msg'
renderNeodocError _ e = pretty e

-- Format the user-facing help text, as printed to the console upon
-- error.
formatHelpText :: String -> Array String -> String -> String -> String
formatHelpText program helpFlags shortHelp errmsg = errmsg
  <> "\n"
  <> (dedent $ unlines $ ("  " <> _) <$> lines (dedent shortHelp))
  <> if A.length helpFlags == 0
      then ""
      else "\n" <> "See "
                    <> program <> " " <> (intercalate "/" helpFlags)
                    <> " for more information"

foreign import jsError :: ∀ a. String -> a -> Error
foreign import readPkgVersionImpl
  :: ∀ e
   . (String -> Maybe String)
  -> Maybe String
  -> Eff e (Maybe String)
