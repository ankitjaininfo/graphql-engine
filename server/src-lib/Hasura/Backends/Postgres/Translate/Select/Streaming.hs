-- | This module defines the top-level translation functions pertaining to
-- streaming selects into Postgres AST.
--
-- Streaming subscriptions are subscriptions based on a user-provided cursor
-- column. Unlike live queries, streaming subscriptions can be used to only get
-- the part that has changed in the query's response, although this will be
-- dependent on the user's choice of the cursor column. The streaming starts
-- from the initial value provided by the user.
module Hasura.Backends.Postgres.Translate.Select.Streaming
  ( mkStreamSQLSelect,
    selectStreamQuerySQL,
  )
where

import Control.Monad.Writer.Strict (runWriter)
import Database.PG.Query (Query)
import Hasura.Backends.Postgres.SQL.DML qualified as S
import Hasura.Backends.Postgres.SQL.Types
import Hasura.Backends.Postgres.SQL.Value (withConstructorFn)
import Hasura.Backends.Postgres.Translate.Select.AnnotatedFieldJSON
import Hasura.Backends.Postgres.Translate.Select.Internal.Aliases (contextualizeBaseTableColumn)
import Hasura.Backends.Postgres.Translate.Select.Internal.Extractor (asJsonAggExtr)
import Hasura.Backends.Postgres.Translate.Select.Internal.GenerateSelect (generateSQLSelectFromArrayNode)
import Hasura.Backends.Postgres.Translate.Select.Internal.Helpers (selectToSelectWith, toQuery)
import Hasura.Backends.Postgres.Translate.Select.Internal.Process (processAnnSimpleSelect)
import Hasura.Backends.Postgres.Translate.Types
  ( CustomSQLCTEs,
    MultiRowSelectNode (MultiRowSelectNode),
    PermissionLimitSubQuery (PLSQNotRequired),
    SelectNode (SelectNode),
    SelectWriter (..),
    SourcePrefixes (SourcePrefixes),
    initialNativeQueryFreshIdStore,
    orderByForJsonAgg,
  )
import Hasura.Backends.Postgres.Types.Column (unsafePGColumnToBackend)
import Hasura.Prelude
import Hasura.RQL.IR.BoolExp
  ( AnnBoolExpFld (AVColumn),
    AnnRedactionExp (..),
    GBoolExp (BoolField),
    OpExpG (AGT, ALT),
    andAnnBoolExps,
  )
import Hasura.RQL.IR.OrderBy (OrderByItemG (OrderByItemG))
import Hasura.RQL.IR.Select
import Hasura.RQL.Types.Backend (Backend)
import Hasura.RQL.Types.BackendType (BackendType (Postgres))
import Hasura.RQL.Types.Column
  ( ColumnInfo (ciColumn, ciName),
    ColumnValue (cvType),
  )
import Hasura.RQL.Types.Common
  ( FieldName (FieldName),
    JsonAggSelect (JASMultipleRows),
    getFieldNameTxt,
  )
import Hasura.RQL.Types.Subscription
  ( CursorOrdering (CODescending),
  )
import Hasura.SQL.Types
  ( CollectableType (CollectableTypeArray, CollectableTypeScalar),
  )
import Language.GraphQL.Draft.Syntax qualified as G

selectStreamQuerySQL ::
  forall pgKind.
  (Backend ('Postgres pgKind), PostgresAnnotatedFieldJSON pgKind) =>
  AnnSimpleStreamSelect ('Postgres pgKind) ->
  Query
selectStreamQuerySQL =
  toQuery
    . selectToSelectWith
    . mkStreamSQLSelect

mkStreamSQLSelect ::
  forall pgKind m.
  ( Backend ('Postgres pgKind),
    PostgresAnnotatedFieldJSON pgKind,
    MonadWriter CustomSQLCTEs m
  ) =>
  AnnSimpleStreamSelect ('Postgres pgKind) ->
  m S.Select
mkStreamSQLSelect (AnnSelectStreamG () fields from perm args strfyNum) = do
  let cursorArg = _ssaCursorArg args
      cursorColInfo = _sciColInfo cursorArg
      annOrderbyCol = AOCColumn cursorColInfo NoRedaction -- TODO(redactionExp): Does a redaction expression need to go here?
      basicOrderType =
        bool S.OTAsc S.OTDesc $ _sciOrdering cursorArg == CODescending
      orderByItems =
        nonEmpty $ pure $ OrderByItemG (Just basicOrderType) annOrderbyCol Nothing
      cursorBoolExp =
        let orderByOpExp = bool ALT AGT $ basicOrderType == S.OTAsc
            sqlExp =
              fromResVars
                (CollectableTypeScalar $ unsafePGColumnToBackend $ cvType (_sciInitialValue cursorArg))
                ["cursor", G.unName $ ciName cursorColInfo]
         in BoolField $ AVColumn cursorColInfo [(orderByOpExp sqlExp)]

      selectArgs =
        noSelectArgs
          { _saWhere =
              Just $ maybe cursorBoolExp (andAnnBoolExps cursorBoolExp) $ _ssaWhere args,
            _saOrderBy = orderByItems,
            _saLimit = Just $ _ssaBatchSize args
          }
      sqlSelect = AnnSelectG fields from perm selectArgs strfyNum Nothing
      permLimitSubQuery = PLSQNotRequired
      ((selectSource, nodeExtractors), SelectWriter {_swJoinTree = joinTree, _swCustomSQLCTEs = customSQLCTEs}) =
        runWriter
          $ flip runReaderT strfyNum
          $ flip evalStateT initialNativeQueryFreshIdStore
          $ processAnnSimpleSelect sourcePrefixes rootFldName permLimitSubQuery sqlSelect
      selectNode = SelectNode nodeExtractors joinTree
      topExtractor =
        asJsonAggExtr JASMultipleRows rootFldAls permLimitSubQuery
          $ orderByForJsonAgg selectSource
      cursorLatestValueExp :: S.SQLExp =
        let columnAlias = ciName cursorColInfo
            pgColumn = ciColumn cursorColInfo
            mkMaxOrMinSQLExp maxOrMin col =
              S.SEFnApp maxOrMin [S.SEIdentifier col] Nothing
            maxOrMinTxt = bool "MIN" "MAX" $ basicOrderType == S.OTAsc
            -- text encoding the cursor value while it's fetched from the DB, because
            -- we can then directly reuse this value, otherwise if this were json encoded
            -- then we'd have to parse the value and then convert it into a text encoded value
            colExp =
              [ S.SELit (G.unName columnAlias),
                S.SETyAnn
                  ( mkMaxOrMinSQLExp maxOrMinTxt
                      $ toIdentifier
                      $ contextualizeBaseTableColumn rootFldIdentifier pgColumn
                  )
                  S.textTypeAnn
              ]
         in -- SELECT json_build_object ('col1', MAX(col1) :: text)

            S.SEFnApp "json_build_object" colExp Nothing
      cursorLatestValueExtractor = S.Extractor cursorLatestValueExp (Just $ S.toColumnAlias $ Identifier "cursor")
      arrayNode = MultiRowSelectNode [topExtractor, cursorLatestValueExtractor] selectNode
  tell customSQLCTEs

  pure $ generateSQLSelectFromArrayNode selectSource arrayNode $ S.BELit True
  where
    rootFldIdentifier = TableIdentifier $ getFieldNameTxt rootFldName
    sourcePrefixes = SourcePrefixes (tableIdentifierToIdentifier rootFldIdentifier) (tableIdentifierToIdentifier rootFldIdentifier)
    rootFldName = FieldName "root"
    rootFldAls = S.toColumnAlias $ toIdentifier rootFldName

    -- TODO: these functions also exist in `resolveMultiplexedValue`, de-duplicate these!
    fromResVars pgType jPath =
      addTypeAnnotation pgType
        $ S.SEOpApp
          (S.SQLOp "#>>")
          [ S.SEQIdentifier $ S.QIdentifier (S.QualifiedIdentifier (TableIdentifier "_subs") Nothing) (Identifier "result_vars"),
            S.SEArray $ map S.SELit jPath
          ]
    addTypeAnnotation pgType =
      flip S.SETyAnn (S.mkTypeAnn pgType) . case pgType of
        CollectableTypeScalar scalarType -> withConstructorFn scalarType
        CollectableTypeArray _ -> id
