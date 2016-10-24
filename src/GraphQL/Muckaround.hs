{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Example from Servant paper:
--
-- http://alpmestan.com/servant/servant-wgp.pdf
module GraphQL.Muckaround
  (
  -- | Experimental things for understanding servant type classes.
    One
  , (:+)
  , Hole
  , valueOf
  -- | Actual GraphQL stuff.
  , (:>)
  , runQuery
  , GetJSON
  , Handler
  , Server
  ) where

import Protolude

import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.GraphQL.AST as AST
import Data.Proxy (Proxy)
import GHC.TypeLits (KnownSymbol, symbolVal)

data One
data e1 :+ e2
data Hole

class HasValue a where
  type Value a r :: *
  valOf :: Proxy a -> (Int -> r) -> Value a r

instance HasValue One where
  type Value One r = r
  valOf _ ret = ret 1

instance (HasValue e1, HasValue e2) => HasValue (e1 :+ e2) where
  type Value (e1 :+ e2) r = Value e1 (Value e2 r)

  valOf _ ret = valOf (Proxy :: Proxy e1) (\v1 ->
                valOf (Proxy :: Proxy e2) (\v2 -> ret (v1 + v2)))

instance HasValue Hole where
  type Value Hole r = Int -> r
  valOf _ ret = ret


valueOf :: HasValue a => Proxy a -> Value a Int
valueOf p = valOf p identity


-- | A query that has all its fragments, variables, and directives evaluated,
-- so that all that is left is a query with literal values.
--
-- 'SelectionSet' is maybe the closest type, but isn't quite what we want, as
-- it still has places for directives and other symbolic values.
type CanonicalQuery = AST.SelectionSet

-- | GraphQL response.
--
-- A GraphQL response must:
--
--   * be a map
--   * have a "data" key iff the operation executed
--   * have an "errors" key iff the operation encountered errors
--   * not include "data" if operation failed before execution (e.g. syntax errors,
--     validation errors, missing info)
--   * not have keys other than "data", "errors", and "extensions"
--
-- Other interesting things:
--
--   * Doesn't have to be JSON, but does have to have maps, strings, lists,
--     and null
--   * Can also support bool, int, enum, and float
--   * Value of "extensions" must be a map
--
-- "data" must be null if an error was encountered during execution that
-- prevented a valid response.
--
-- "errors"
--
--   * must be a non-empty list
--   * each error is a map with "message", optionally "locations" key
--     with list of locations
--   * locations are maps with 1-indexed "line" and "column" keys.
type Response = Aeson.Value

-- | A GraphQL application takes a canonical query and returns a response.
-- XXX: Really unclear what type this should be. Does it need IO? Generic
-- across Monad? Something analogous to the continuation-passing style of
-- WAI.Application?
type Application = CanonicalQuery -> IO Response


-- | A field within an object.
--
-- e.g.
--  "foo" :> Foo
data (name :: k) :> a deriving (Typeable)

-- XXX: This structure is cargo-culted from Servant, even though jml doesn't fully
-- understand it yet.
--
-- XXX: Rename "Handler" to "Resolver"? Resolver is a technical term within
-- GraphQL, so only use it if it matches exactly.
type Handler = IO
-- XXX: Rename to Graph & GraphT?
type Server api = ServerT api Handler

class HasGraph api where
  type ServerT api (m :: * -> *) :: *
  resolve :: Proxy api -> Server api -> Application

-- XXX: GraphQL responses don't *have* to be JSON. See 'Response'
-- documentation for more details.
data GetJSON (t :: *)

runQuery :: HasGraph api => Proxy api -> Server api -> CanonicalQuery -> IO Response
runQuery = resolve

instance Aeson.ToJSON t => HasGraph (GetJSON t) where
  type ServerT (GetJSON t) m = m t

  resolve Proxy handler [] = Aeson.toJSON <$> handler
  resolve _ _ _ = empty

-- | A field within an object.
--
-- e.g.
--  "foo" :> Foo
instance (KnownSymbol name, HasGraph api) => HasGraph (name :> api) where
  type ServerT (name :> api) m = ServerT api m

  resolve Proxy subApi query =
    case lookup query fieldName of
      Nothing -> empty  -- XXX: Does this even work?
      Just (alias, subQuery) -> buildField alias (resolve (Proxy :: Proxy api) subApi subQuery)
    where
      fieldName = toS (symbolVal (Proxy :: Proxy name))
      -- XXX: What to do if there are argumentS?
      -- XXX: This is almost certainly partial.
      lookup q f = listToMaybe [ (a, s) | AST.SelectionField (AST.Field a n [] _ s) <- q
                                        , n == f
                                        ]
      buildField alias' value = do
        value' <- value
        -- XXX: An object? Really? jml thinks this should just be a key/value
        -- pair and that some other layer should assemble an object.
        pure (Aeson.object [alias' .= value'])