-- |
-- | This module defines the entry point and surface area of the Docopt
-- | compiler.
-- |

module Docopt.Parser.Docopt where

import Prelude
import Data.Either
import qualified Text.Parsing.Parser as P
import qualified Text.Parsing.Parser.Combinators as P
import qualified Text.Parsing.Parser.Pos as P
import qualified Text.Parsing.Parser.String as P
import qualified Docopt.Parser.Lexer as Lexer
import qualified Docopt.Parser.Usage as Usage
import qualified Docopt.Parser.Scanner as Scanner
import qualified Docopt.Parser.Gen as Gen
import Docopt.Parser.Base (debug)

data DocoptError
  = ScanError  P.ParseError
  | LexError   P.ParseError
  | ParseError P.ParseError
  | GenError   String
  | RunError   P.ParseError

instance showError :: Show DocoptError where
  show (ScanError err)  = "ScanError "  ++ show err
  show (LexError err)   = "LexError "   ++ show err
  show (ParseError err) = "ParseError " ++ show err
  show (GenError msg)   = "GenError "   ++ show msg
  show (RunError err)   = "RunError "   ++ show err

docopt :: String -> String -> Either DocoptError Unit
docopt source input = do

  debug "Scanning..."
  Scanner.Docopt usageSrc _ <- wrapParseError ScanError do
    P.runParser source Scanner.scanDocopt
  debug usageSrc

  debug "Lexing..."
  usageToks <- wrapParseError LexError do
    flip P.runParser Lexer.parseTokens usageSrc
  debug usageToks

  debug "Parsing..."
  usages <- wrapParseError ParseError do
    flip Lexer.runTokenParser Usage.parseUsage usageToks
  debug usages

  debug "Generating and applying parser..."
  result <- wrapParseError RunError $ flip P.runParser
    (Gen.generateParser usages)
    input
  debug result

  where
    wrapParseError :: forall a. (P.ParseError -> DocoptError)
                             -> Either P.ParseError a
                             -> Either DocoptError  a
    wrapParseError f = either (Left <<< f) return
