module Text.Wrap where

import Prelude
import Data.Array as A
import Data.String as Str
import Data.String (Pattern(..))
import Data.String.CodeUnits (toCharArray)
import Data.Maybe (maybe)

dedent :: String -> String
dedent txt =
  let lines :: Array String
      lines = Str.split (Pattern "\n") txt
      nonEmpty :: String -> Boolean
      nonEmpty = (_ /= 0) <<< Str.length <<< Str.trim
      shortestLeading :: Int
      shortestLeading = maybe 0 identity (A.head $ A.sort $ countLeading
                               <$> (A.filter nonEmpty lines))
      isWhitespace :: Char -> Boolean
      isWhitespace ' '  = true
      isWhitespace '\n' = true
      isWhitespace '\t' = true
      isWhitespace _    = false
      countLeading :: String -> Int
      countLeading line = A.length $ A.takeWhile isWhitespace (toCharArray line)
   in Str.joinWith "\n" ((Str.drop shortestLeading) <$> lines)

