-- | Input Parser Generator for Docopt
-- |
-- | > Given a un-ambigious specification as input, generate a parser that can
-- | > be applied to user input.
-- |
-- | ===

module Language.Docopt.ParserGen.Parser (
    genUsageParser
  , Parser()
  ) where

import Prelude
import Control.Plus (empty)
import Debug.Trace
import Control.Monad.State (State(), evalState)
import Control.Apply ((*>), (<*))
import Data.Either (Either(..), either)
import Data.Maybe (Maybe(..), isJust, maybe)
import Data.List (List(..), foldM, (:), singleton, some, toList, delete, length
                 , head, many, tail, fromList, filter, reverse, concat)
import Control.Alt ((<|>))
import Control.Lazy (defer)
import Data.Foldable (foldl, intercalate, for_, all)
import Data.String (fromCharArray, stripPrefix)
import qualified Data.List as L
import qualified Data.List.Unsafe as LU
import qualified Data.Array as A
import qualified Data.Array.Unsafe as AU
import Data.Array (uncons)
import Data.Tuple (Tuple(..))
import Data.Monoid (mempty)
import Data.Map (Map())
import qualified Data.Map as Map

import qualified Text.Parsing.Parser             as P
import qualified Text.Parsing.Parser.Combinators as P
import qualified Text.Parsing.Parser.Pos         as P
import qualified Text.Parsing.Parser.String      as P

import qualified Language.Docopt.Errors   as D
import qualified Language.Docopt.Value    as D
import qualified Language.Docopt.Argument as D
import qualified Language.Docopt.Usage    as D
import qualified Language.Docopt.Option   as O

import Language.Docopt.ParserGen.Token
import Language.Docopt.ParserGen.ValueMapping
import Language.Docopt.Parser.Base (alphaNum, space, getInput, debug)

type Parser a = P.Parser (List Token) a

--------------------------------------------------------------------------------
-- Input Token Parser ----------------------------------------------------------
--------------------------------------------------------------------------------

-- | Test the token at the head of the stream
token :: forall a. (Token -> Maybe a) -> Parser a
token test = P.ParserT $ \(P.PState { input: toks, position: pos }) ->
  return $ case toks of
    Cons tok xs ->
      case test tok of
        Just a ->
          let nextpos = pos -- neglect pos (for now)
          in
            { consumed: true
            , input:    xs
            , result:   Right a
            , position: nextpos }
        -- XXX: Fix this error message, it makes no sense!
        Nothing -> P.parseFailed toks pos "a better error message!"
    _ -> P.parseFailed toks pos "expected token, met EOF"

data Acc a
  = Free (Parser a)
  | Pending (Parser a) (List D.Argument)

eoa :: Parser D.Value
eoa = token go P.<?> "--"
  where
    go (EOA xs) = Just (D.ArrayValue (fromList xs))
    go _        = Nothing

command :: String -> Parser D.Value
command n = token go P.<?> "command " ++ show n
  where
    go (Lit s) | s == n = Just (D.BoolValue true)
    go _                = Nothing

positional :: String -> Parser D.Value
positional n = token go P.<?> "positional argument " ++ show n
  where
    go (Lit v) = Just (D.StringValue v)
    go _       = Nothing

type HasConsumedArg = Boolean
data OptParse = OptParse D.Value (Maybe Token) HasConsumedArg

longOption :: O.Name -> (Maybe O.Argument) -> Parser D.Value
longOption n a = P.ParserT $ \(P.PState { input: toks, position: pos }) ->
  return $ case toks of
    Cons tok xs ->
      case go tok (head xs) of
        Left e -> P.parseFailed toks pos e
        Right (OptParse v newtok hasConsumedArg) ->
          { consumed: maybe true (const false) newtok
          , input:    (maybe empty singleton newtok) ++
                      (if hasConsumedArg then (LU.tail xs) else xs)
          , result:   Right v
          , position: pos -- ignore pos (for now)
          }
    _ -> P.parseFailed toks pos "expected token, met EOF"

  where

    takesArg = isJust a

    -- case 1:
    -- The name is an exact match
    go (LOpt n' v) atok | takesArg && (n' == n)
      = case v of
          Just s ->
            return $ OptParse (D.StringValue s) Nothing false
          _  -> return case atok of
            Just (Lit s) -> OptParse (D.StringValue s)  Nothing true
            _            -> OptParse (D.BoolValue true) Nothing false

    -- case 2:
    -- The name is an exact match and takes no argument
    go (LOpt n' _) _ | (not takesArg) && (n' == n)
      = return $ OptParse (D.BoolValue true) Nothing false

    -- case 3:
    -- The name is a substring of the input and no explicit argument has been
    -- provdided.
    go (LOpt n' Nothing) atok | takesArg
      = case stripPrefix n n' of
          Just s -> return $ OptParse (D.StringValue s) Nothing false
          _      -> Left "Invalid substring"

    go _ _ = Left "Invalid token"

shortOption :: Char -> (Maybe O.Argument) -> Parser D.Value
shortOption f a = P.ParserT $ \(P.PState { input: toks, position: pos }) ->
  return $ case toks of
    Cons tok xs ->
      case go tok (head xs) of
        Left e -> P.parseFailed toks pos e
        Right (OptParse v newtok hasConsumedArg) ->
          { consumed: maybe true (const false) newtok
          , input:    (maybe empty singleton newtok) ++
                      (if hasConsumedArg then (LU.tail xs) else xs)
          , result:   Right v
          , position: pos -- ignore pos
          }
    _ -> P.parseFailed toks pos "expected token, met EOF"

  where

    takesArg = isJust a
    def      = maybe Nothing (\(O.Argument { value: v }) -> v) a

    -- case 1:
    -- The leading flag matches, there are no stacked options, and an explicit
    -- argument may have been passed.
    go (SOpt f' xs v) atok | (f' == f) && takesArg && (A.length xs == 0)
      = case v of
          Just val -> return $ OptParse (D.StringValue val) Nothing false
          _  -> return case atok of
            Just (Lit s) -> OptParse (D.StringValue s) Nothing true
            _ -> OptParse (D.BoolValue true)
                          Nothing
                          false

    -- case 2:
    -- The leading flag matches, there are stacked options, no explicit
    -- argument has been passed and the option takes an argument.
    go (SOpt f' xs v) _ | (f' == f) && takesArg && (A.length xs > 0)
      = do
        let a = fromCharArray xs ++ maybe "" id v
        return $ OptParse (D.StringValue a)
                          Nothing
                          false

    -- case 3:
    -- The leading flag matches, there are stacked options, the option takes
    -- no argument and an explicit argument has not been provided.
    go (SOpt f' xs v) _ | (f' == f) && (takesArg == false) && (A.length xs > 0)
      = return $ OptParse (D.BoolValue true)
                          (Just $ SOpt (AU.head xs) (AU.tail xs) v)
                          false

    -- case 4:
    -- The leading flag matches, there are no stacked options and the option
    -- takes no argument - total consumption!
    go (SOpt f' xs _) _ | (f' == f) && (takesArg == false) && (A.length xs == 0)
      = return $ OptParse (D.BoolValue true)
                          Nothing
                          false

    go a b = Left $ "Invalid token " ++ show a ++ " (input: " ++ show b ++ ")"

eof :: Parser Unit
eof = P.ParserT $ \(P.PState { input: s, position: pos }) ->
  return $ case s of
    Nil -> { consumed: false, input: s, result: Right unit, position: pos }
    _   -> P.parseFailed s pos $
              "Trailing input: "
            ++ (intercalate ", " $ prettyPrintToken <$> s)

-- | Generate a parser for a single program usage.
genUsageParser :: D.Usage -> Parser (Tuple D.Branch (List ValueMapping))
genUsageParser (D.Usage xs) = do
  P.choice $ xs <#> \x -> Tuple x <$> genBranchParser x
  <* eof

-- | Generate a parser for a single usage branch
genBranchParser :: D.Branch -> Parser (List (Tuple D.Argument D.Value))
genBranchParser (D.Branch xs) = do
  either
    (\_   -> P.fail "Failed to generate parser")
    (\acc -> case acc of
      Free p       -> p
      Pending p xs -> do
        a  <- p
        as <- genExhaustiveParser xs
        return (a ++ as))
    (foldM step (Free $ pure empty) xs)
  where

    -- Given a list of arguments, try parse them all in any order.
    -- The only requirement is that all input is consumed in the end.
    genExhaustiveParser :: List D.Argument
                       -> Parser (List (Tuple D.Argument D.Value))
    genExhaustiveParser Nil = pure empty
    genExhaustiveParser ps  = do
      draw ps (length ps)
      where
        -- iterate over `ps` until a match `x` is found, then, recursively
        -- apply `draw` until the parser fails, with a modified `ps`.
        draw :: List D.Argument
             -> Int
             -> Parser (List (Tuple D.Argument D.Value))
        draw pss@(Cons p ps') n | n >= 0 = (do
          xs <- genParser p

          -- verify the arguments for parsed set of options
          -- when an option takes anything but a bool value, i.e. it is not
          -- a switch, an explicit argument *must* be provided.
          let ys = map (\(Tuple a _) -> a) $
                    filter
                      (\(Tuple a v) -> (D.takesArgument a)
                                    && (not $ D.isFlag a)
                                    && (D.isBoolValue v))
                      xs
          if (length ys > 0)
            then P.fail $ "Missing required arguments for "
                        ++ intercalate ", " (D.prettyPrintArg <$> ys)
            else return unit

          xss <- if D.isRepeatable p
                      then draw pss (length pss)
                      else draw (ps') (length ps')
          return $ xs ++ xss
        ) <|> (defer \_ -> draw (ps' ++ singleton p) (n - 1))
        draw ps' n | (length ps' > 0) && (n < 0) = do
          let rest = filter
                      (\p -> (not $ D.isRepeatable p)
                          && (not $ D.hasDefault p))
                      (reverse ps')
          if (length rest > 0)
            then P.fail $
              "Missing required options: "
                ++ intercalate ", " (D.prettyPrintArg <$> rest)
            else return empty
        draw _ _ = return empty

    -- Options always transition to the `Pending state`
    step (Free p) x@(D.Option _) = Right $ Pending p (singleton x)
    step (Free p) x@(D.Group _ bs _) | isFree x
      = Right $ Pending p (singleton x)

    -- Any other argument causes immediate evaluation
    step (Free p) x = Right $ Free do
      a  <- p
      as <- genParser x
      return $ a ++ as

    -- Options always keep accumulating
    step (Pending p xs) x@(D.Option _) = Right $ Pending p (x:xs)

    -- Any non-options always leaves the pending state
    step (Pending p xs) y = Right $
      Free do
        a   <- p
        as  <- genExhaustiveParser xs
        ass <- genParser y
        return (a ++ as ++ ass)

    -- Parser generator for a single `Argument`
    genParser :: D.Argument -> Parser (List (Tuple D.Argument D.Value))

    -- Generate a parser for a `Command` argument
    genParser x@(D.Command n) = (do
      singleton <<< Tuple x <$> do
        command n
      ) P.<?> "command: " ++ (show $ D.prettyPrintArg x)

    -- Generate a parser for a `EOA` argument
    genParser x@(D.EOA) = (do
      singleton <<< Tuple x <$> do
        eoa <|> (return $ D.ArrayValue []) -- XXX: Fix type
      ) P.<?> "end of arguments: \"--\""

    -- Generate a parser for a `Stdin` argument
    genParser x@(D.Stdin) = (do
      singleton <<< Tuple x <$> do
        -- stdin always succeeds, as it is not actually an argument on argv.
        -- XXX: Should docopt check `process.stdin.isTTY` at this stage, or
        --      even at all?
        return (D.BoolValue true)
      ) P.<?> "stdin: \"-\""

    -- Generate a parser for a `Positional` argument
    genParser x@(D.Positional n r) = (do
      if r then (some go) else (singleton <$> go)
      ) P.<?> "positional argument: " ++ (show $ D.prettyPrintArg x)
      where go = Tuple x <$> (positional n)

    -- Generate a parser for a `Option` argument
    genParser x@(D.Option (O.Option o)) = (do
      if o.repeatable then (some go) else (singleton <$> go)
      ) P.<?> "option: " ++ (show $ D.prettyPrintArg x)
      where
        go = do
          P.choice $ P.try <$> [
            Tuple x <$> (mkLoptParser o.name o.arg)
          , Tuple x <$> (mkSoptParser o.flag o.arg)
          ]

        mkLoptParser (Just n) a = longOption n a
        mkLoptParser Nothing _  = P.fail "no long name"

        mkSoptParser (Just f) a = shortOption f a
        mkSoptParser Nothing _  = P.fail "no flag"

    -- Generate a parser for a argument `Group`
    genParser x@(D.Group optional bs repeated) = do
      concat <$>
        let mod    = if optional then P.option empty else \p -> p
            parser = if repeated then many go else singleton <$> go
         in mod parser
      where go = if length bs > 0
                    then P.choice $ P.try <<< genBranchParser <$> bs
                    else return empty

    isFree :: D.Argument -> Boolean
    isFree (D.Option _)     = true
    isFree (D.Group _ bs _) = all (\(D.Branch b) -> all isFree b) bs
    isFree _                = false
