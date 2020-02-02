-- Reduce the neodoc output into a easily consume key => value map.
--
-- This is done by:
--      1. reducing the matched branch down to a set of arguments, merging them
--         as needed (lossy).
--      2. reducing the matched key-values down to a set of key -> [ value ]
--         (lossless)
--      3. applying values to the arguments in the branch processed in (1)
--         merging duplicate occurences as makes sense for that option
--      4. culling values considered empty

module Neodoc.Evaluate.Reduce (reduce)
where

import Prelude
  ( bind, not, pure, ($), (&&), (/=)
  , (<#>), (<$>), (<<<), (<>), (||)
  )

import Control.Alt ((<|>))
import Data.Array as A
import Data.Bifunctor (rmap, lmap)
import Data.Foldable (all, foldl, maximum)
import Data.Function (flip)
import Data.List (List(..), catMaybes, concat, filter, nub, reverse, singleton)
import Data.Map (Map, toUnfoldable)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust, fromMaybe)
import Data.Tuple (Tuple)
import Data.Tuple.Nested ((/\))
import Partial.Unsafe (unsafePartial)

import Neodoc.ArgParser.Arg (getArgKey)
import Neodoc.ArgParser.KeyValue (KeyValue)
import Neodoc.Data.Description (Description(..))
import Neodoc.Data.Layout (Branch, Layout(..))
import Neodoc.Data.OptionArgument (isOptionArgumentOptional)
import Neodoc.Data.SolvedLayout (SolvedLayoutArg)
import Neodoc.Data.SolvedLayout as Solved
import Neodoc.Env (Env)
import Neodoc.Evaluate.Annotate
  (AnnotatedLayout, WithDescription, annotateLayout, findArgKeys)
import Neodoc.Evaluate.Key (Key(..), toKey, toStrKeys)
import Neodoc.OptionAlias (NonEmpty, (:|))
import Neodoc.Value (Value(..), isBoolValue)
import Neodoc.Value as Value
import Neodoc.Value.Origin as Origin
import Neodoc.Value.RichValue (RichValue(..), unRichValue)


type FacelessLayout = Layout FacelessLayoutArg

data FacelessLayoutArg
  = Command     Boolean
  | Positional  Boolean
  | Option      (Maybe Boolean {- argument optional? -}) Boolean
  | EOA
  | Stdin


mergeVals
  :: forall a b c d
  .  Tuple a (Tuple b RichValue)
  -> Tuple c (Tuple d RichValue)
  -> Tuple a (Tuple b RichValue)
mergeVals (a /\ d /\ RichValue v) (_ /\ _ /\ RichValue v') =
  a /\ d /\ (RichValue $
    { origin: unsafePartial $ fromJust $ maximum [ v.origin, v'.origin ]
    , value:  ArrayValue $ Value.intoArray v'.value
                    <> Value.intoArray v.value
    })


fillValues
  :: Map Key (WithDescription FacelessLayoutArg)
  -> Map Key (List RichValue)
  -> Map Key (Tuple FacelessLayoutArg (Tuple (Maybe Description) RichValue))
fillValues target input =
  let
    origin cmp o = \x -> (_.origin $ unRichValue x) `cmp` o

    -- 1. look up the values. Note that the lookup may yield `Nothing`,
    --    meaning that it is ought to be omitted.
    newValues = toUnfoldable target <#> \(k /\ (a /\ d)) -> do
      vs <- Map.lookup k input
      let vs' = filter (origin (/=) Origin.Empty) vs
          vs'' = filter (origin (/=) Origin.Default) vs'
          vs''' = case vs'' of
                      Nil -> nub vs'
                      vs  -> vs
          vs'''' = vs''' <#> \(RichValue v) -> RichValue $ v {
                    value = if isRepeatable a
                              then ArrayValue $ Value.intoArray v.value
                              else v.value
                    }
      -- return: k => arg , description , value
      pure $ vs'''' <#> \v -> k /\ (a /\ d /\ v)
  in
    Map.fromFoldableWith mergeVals $ concat $ catMaybes $ newValues


finalFold
  :: Map Key (Tuple FacelessLayoutArg (Tuple (Maybe Description) RichValue))
  -> Map String RichValue
finalFold m =
  let
    tupleList :: List (Tuple Key (Tuple FacelessLayoutArg (Tuple (Maybe Description) RichValue)))
    tupleList = Map.toUnfoldable m

    tupleToList
      :: Tuple Key (Tuple FacelessLayoutArg (Tuple (Maybe Description) RichValue))
      -> List (Tuple String RichValue)
    tupleToList (k /\ (a /\ _ /\ RichValue rv)) =
      let
        v = fromMaybe rv.value do
              if isFlag a || isCommand a
              then case rv.value of
                ArrayValue xs -> pure
                  if all isBoolValue xs && not (A.null xs)
                  then
                    IntValue (A.length $ flip A.filter xs \x ->
                      case x of
                        BoolValue b -> b
                        _           -> false
                    )
                  else ArrayValue xs

                BoolValue b ->
                  if isRepeatable a
                  then pure
                    if b
                    then IntValue 1
                    else IntValue 0
                  else Nothing

                _ -> Nothing

              else Nothing
      in
        toStrKeys k <#> (_ /\ (RichValue $ rv { value = v }))

    x :: List (List (Tuple String RichValue))
    x = tupleList <#> tupleToList

  in
    Map.fromFoldable $ concat x


reduce
  :: Env
  -> List Description
  -> Maybe (Branch SolvedLayoutArg)
  -> List KeyValue
  -> Map String Value
reduce _ _ Nothing _ = Map.empty
reduce env descriptions (Just branch) vs = (_.value <<< unRichValue) <$>
  let
      -- 1. annotate all layout elements with their description
      annotedBranch :: NonEmpty List (Layout (Tuple SolvedLayoutArg (Maybe Description)))
      annotedBranch = annotateLayout descriptions <$> branch

      -- 2. derive a set of arguments and their description for the matched
      --    branch. this removes all levels of nesting and is a lossy operation.
      --    it is essentially a target of values we are ought to fill from what
      --    the parser derived
      target :: Map Key (Tuple FacelessLayoutArg (Maybe Description))
      target = expandLayout (Group false false (annotedBranch :| Nil))

      -- 3. Collect the input map. This map reduces the matched values by their
      --    denominator. Currently, this denominator is the `Key` derived from
      --    the option's name as it was matched.
      input :: Map Key (List RichValue)
      input = Map.fromFoldableWith (<>) $
                rmap singleton <$>
                lmap (Key <<< findArgKeys descriptions) <$>
                reverse (lmap getArgKey <$> vs)

      -- 4. fill the values for each key of the target map
      values :: Map Key (Tuple FacelessLayoutArg (Tuple (Maybe Description) RichValue))
      values = fillValues target input

  in
    finalFold values


-- Reduce a solved layout arg to a faceless layout arg, that is a layout arg
-- whose identifying properties have been stripped since they are already
-- present in that object's key.
toFacelessLayoutArg
  :: SolvedLayoutArg
  -> FacelessLayoutArg
toFacelessLayoutArg = go
  where
  go (Solved.Option _ mA  r) = Option (isOptionArgumentOptional <$> mA) r
  go (Solved.Positional _ r) = Positional r
  go (Solved.Command    _ r) = Command r
  go Solved.EOA              = EOA
  go Solved.Stdin            = Stdin


-- Expand a layout into a map of `Key => Argument`, where `Key` must uniquely
-- identify the argument in order to avoid loss.
expandLayout
  :: AnnotatedLayout SolvedLayoutArg
  -> Map Key (WithDescription FacelessLayoutArg)
expandLayout (Elem x) = Map.singleton (toKey x) (lmap toFacelessLayoutArg x)
expandLayout (Group o r xs) =
  let -- 1. expand each branch, reducing each to a `Map`
      branches = fold inSameBranch <<< (expandLayout <$> _) <$> xs
      -- 2. apply this group's repeatablity to all elements across all branches
      branches' = (lmap (setRepeatableOr r) <$> _) <$> branches
   in -- 3. reduce all branches into a single branch
      fold acrossBranches branches'

  where

  inSameBranch   = mergeArgs true
  acrossBranches = mergeArgs false

  mergeArgs
    :: Boolean
    -> WithDescription FacelessLayoutArg
    -> WithDescription FacelessLayoutArg
    -> WithDescription FacelessLayoutArg

  -- note: two options identified by the same key clashed.
  --       we can only keep one, so we combine them as best possible.
  -- note: we simply choose the left option's name since the name won't matter
  --       too much as long as it resolves to the same description which is
  --       implicitly true due to the encapsulating `Key`. The same applies
  --       for the option's option-argument.
  -- idea: maybe we need a more appropriate data structure to capture the
  --       semantics of this reduction?
  mergeArgs forceR (x@((Option mA r) /\ mDesc)) ((Option mA' r') /\ mDesc')
    = let
        mA'' = do
          aO  <- mA  <|> mA'
          aO' <- mA' <|> mA
          pure $ aO || aO'
        mDesc'' = do
          desc  <- mDesc  <|> mDesc'
          desc' <- mDesc' <|> mDesc
          case desc /\ desc' of
            (OptionDescription a b c d e) /\ (OptionDescription a' b' c' d' e') ->
              pure $ OptionDescription a b (c <|> c') (d <|> d') (e <|> e')
            (OptionDescription a b c d e) /\ _ ->
              pure $ OptionDescription a b c d e
            _ /\ (OptionDescription a b c d e) ->
              pure $ OptionDescription a b c d e
            _ -> Nothing
      in Option mA'' (forceR || r || r') /\  mDesc''
  mergeArgs forceR (x /\ mDesc) (y /\ _)
    = setRepeatableOr (forceR || isRepeatable y) x /\ mDesc

  fold f = foldl (Map.unionWith f) Map.empty


isRepeatable :: FacelessLayoutArg -> Boolean
isRepeatable (Command    r) = r
isRepeatable (Positional r) = r
isRepeatable (Option   _ r) = r
isRepeatable _ = false


setRepeatable :: Boolean -> FacelessLayoutArg -> FacelessLayoutArg
setRepeatable r (Command    _) = Command    r
setRepeatable r (Positional _) = Positional r
setRepeatable r (Option   x _) = Option   x r
setRepeatable _ x = x


isFlag :: FacelessLayoutArg -> Boolean
isFlag (Option Nothing _) = true
isFlag _ = false


isCommand :: FacelessLayoutArg -> Boolean
isCommand (Command _) = true
isCommand _ = false


setRepeatableOr :: Boolean -> FacelessLayoutArg -> FacelessLayoutArg
setRepeatableOr r x = setRepeatable (isRepeatable x || r) x
