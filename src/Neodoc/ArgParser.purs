module Neodoc.ArgParser
  ( run
  , module Reexports
  )
where

import Prelude (bind, ($))
import Data.Either (Either)
import Data.Bifunctor (lmap)
import Data.List (fromFoldable)
import Neodoc.Env (Env)
import Neodoc.Spec (Spec)
import Neodoc.Data.SolvedLayout (SolvedLayout)
import Neodoc.ArgParser.Options (Options)
import Neodoc.Parsing.Parser (extractError)
import Neodoc.ArgParser.Type
import Neodoc.ArgParser.Parser (parse)
import Neodoc.ArgParser.Result (ArgParseResult)
import Neodoc.ArgParser.Lexer as Lexer

import Neodoc.ArgParser.Options (Options) as Reexports
import Neodoc.ArgParser.Result (ArgParseResult(..), getResult) as Reexports

run
  :: ∀ r
   . Spec SolvedLayout
  -> Options r
  -> Env
  -> Array String
  -> Either ArgParseError ArgParseResult
run spec opts env input = do
  toks <- runLexer $ Lexer.lex (fromFoldable input) opts
  runParser $ parse spec opts env toks

  where
  runLexer = lmap malformedInputError
  runParser = lmap (extractError genericError)
