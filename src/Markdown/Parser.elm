module Markdown.Parser exposing (parse, deadEndToString)

{-|

@docs parse, deadEndToString

-}

import Dict exposing (Dict)
import Helpers exposing (endOfLineOrFile)
import HtmlParser exposing (Node(..))
import Markdown.Block as Block exposing (Block, Inline, ListItem, Task)
import Markdown.CodeBlock
import Markdown.Inline as Inline
import Markdown.InlineParser
import Markdown.LinkReferenceDefinition as LinkReferenceDefinition exposing (LinkReferenceDefinition)
import Markdown.ListItem as ListItem
import Markdown.OrderedList
import Markdown.RawBlock as RawBlock exposing (Attribute, RawBlock(..), UnparsedInlines(..))
import Markdown.Table
import Markdown.TableParser as TableParser
import Markdown.UnorderedList
import Parser
import Parser.Advanced as Advanced exposing ((|.), (|=), Nestable(..), Step(..), andThen, chompIf, chompWhile, getChompedString, loop, map, oneOf, problem, succeed, symbol, token)
import Parser.Extra exposing (zeroOrMore)
import Parser.Token as Token
import ThematicBreak


{-| Try parsing a markdown String into `Markdown.Block.Block`s.

Often you'll want to render these `Block`s directly:

    render renderer markdown =
        markdown
            |> Markdown.Parser.parse
            |> Result.mapError deadEndsToString
            |> Result.andThen (\ast -> Markdown.Renderer.render renderer ast)

    deadEndsToString deadEnds =
        deadEnds
            |> List.map Markdown.Parser.deadEndToString
            |> String.join "\n"

But you can also do a lot with the `Block`s before passing them through:

  - Transform the `Block`s ([example: make each heading one level deeper](TODO))
  - Use the blocks to gather metadata about the markdown document ([example: building a table of contents from `Block`s](TODO))

-}
parse : String -> Result (List (Advanced.DeadEnd String Parser.Problem)) (List Block)
parse input =
    -- first parse the file as raw blocks
    case Advanced.run (rawBlockParser |. Helpers.endOfFile) input of
        Err e ->
            Err e

        Ok v ->
            -- then parse the inlines of each raw block
            case parseAllInlines v of
                Err e ->
                    -- NOTE these messages get an incorrect location,
                    -- because they are parsed outside of the main (raw block) parser context.
                    Advanced.run (Advanced.problem e) ""

                Ok blocks ->
                    let
                        -- TODO find a better way to do this
                        -- e.g. make sure they are never generated
                        isNotEmptyParagraph block =
                            case block of
                                Block.Paragraph [] ->
                                    False

                                _ ->
                                    True
                    in
                    Ok (List.filter isNotEmptyParagraph blocks)


deadEndsToString : List (Advanced.DeadEnd String Parser.Problem) -> String
deadEndsToString deadEnds =
    deadEnds
        |> List.map deadEndToString
        |> String.join "\n"


{-| Turn a parsing problem into the default String representation.
-}
deadEndToString : Advanced.DeadEnd String Parser.Problem -> String
deadEndToString deadEnd =
    "Problem at row " ++ String.fromInt deadEnd.row ++ "\n" ++ problemToString deadEnd.problem


problemToString : Parser.Problem -> String
problemToString problem =
    case problem of
        Parser.Expecting string ->
            "Expecting " ++ string

        Parser.ExpectingInt ->
            "Expecting int"

        Parser.ExpectingHex ->
            "Expecting hex"

        Parser.ExpectingOctal ->
            "Expecting octal"

        Parser.ExpectingBinary ->
            "Expecting binary"

        Parser.ExpectingFloat ->
            "Expecting float"

        Parser.ExpectingNumber ->
            "Expecting number"

        Parser.ExpectingVariable ->
            "Expecting variable"

        Parser.ExpectingSymbol string ->
            "Expecting symbol " ++ string

        Parser.ExpectingKeyword string ->
            "Expecting keyword " ++ string

        Parser.ExpectingEnd ->
            "Expecting keyword end"

        Parser.UnexpectedChar ->
            "Unexpected char"

        Parser.Problem problemDescription ->
            problemDescription

        Parser.BadRepeat ->
            "Bad repeat"


type alias Parser a =
    Advanced.Parser String Parser.Problem a


inlineParseHelper : LinkReferenceDefinitions -> UnparsedInlines -> List Block.Inline
inlineParseHelper referencesDict (UnparsedInlines unparsedInlines) =
    let
        referencesDict2 =
            referencesDict
                |> List.map (Tuple.mapSecond (\{ destination, title } -> ( destination, title )))
                |> Dict.fromList

        --
        --myReferences =
        --    Dict.fromList
        --        [ ( "foo", { destination = "/url", title = Just "title" } )
        --        ]
    in
    Markdown.InlineParser.parse referencesDict2 unparsedInlines
        |> List.map mapInline


mapInline : Inline.Inline -> Block.Inline
mapInline inline =
    case inline of
        Inline.Text string ->
            Block.Text string

        Inline.HardLineBreak ->
            Block.HardLineBreak

        Inline.CodeInline string ->
            Block.CodeSpan string

        Inline.Link string maybeString inlines ->
            Block.Link string maybeString (inlines |> List.map mapInline)

        Inline.Image string maybeString inlines ->
            Block.Image string maybeString (inlines |> List.map mapInline)

        Inline.HtmlInline node ->
            node
                |> nodeToRawBlock
                |> Block.HtmlInline

        Inline.Emphasis level inlines ->
            case level of
                1 ->
                    Block.Emphasis (inlines |> List.map mapInline)

                2 ->
                    Block.Strong (inlines |> List.map mapInline)

                _ ->
                    -- TODO fix this
                    Block.Strong (inlines |> List.map mapInline)


toHeading : Int -> Result Parser.Problem Block.HeadingLevel
toHeading level =
    case level of
        1 ->
            Ok Block.H1

        2 ->
            Ok Block.H2

        3 ->
            Ok Block.H3

        4 ->
            Ok Block.H4

        5 ->
            Ok Block.H5

        6 ->
            Ok Block.H6

        _ ->
            Err ("A heading with 1 to 6 #'s, but found " ++ String.fromInt level |> Parser.Expecting)


type InlineResult
    = EmptyBlock
    | ParsedBlock Block
    | InlineProblem Parser.Problem


parseInlines : LinkReferenceDefinitions -> RawBlock -> InlineResult
parseInlines linkReferences rawBlock =
    case rawBlock of
        Heading level unparsedInlines ->
            case toHeading level of
                Ok parsedLevel ->
                    unparsedInlines
                        |> inlineParseHelper linkReferences
                        |> Block.Heading parsedLevel
                        |> ParsedBlock

                Err e ->
                    InlineProblem e

        Body unparsedInlines ->
            unparsedInlines
                |> inlineParseHelper linkReferences
                |> Block.Paragraph
                |> ParsedBlock

        Html html ->
            Block.HtmlBlock html
                |> ParsedBlock

        UnorderedListBlock unparsedItems ->
            let
                parseItem unparsed =
                    let
                        parsedInlines =
                            parseRawInline linkReferences identity unparsed.body

                        task =
                            case unparsed.task of
                                Just False ->
                                    Block.IncompleteTask

                                Just True ->
                                    Block.CompletedTask

                                Nothing ->
                                    Block.NoTask
                    in
                    Block.ListItem task parsedInlines
            in
            unparsedItems
                |> List.map parseItem
                |> Block.UnorderedList
                |> ParsedBlock

        OrderedListBlock startingIndex unparsedInlines ->
            unparsedInlines
                |> List.map (parseRawInline linkReferences identity)
                |> Block.OrderedList startingIndex
                |> ParsedBlock

        CodeBlock codeBlock ->
            Block.CodeBlock codeBlock
                |> ParsedBlock

        ThematicBreak ->
            ParsedBlock Block.ThematicBreak

        BlankLine ->
            EmptyBlock

        BlockQuote rawBlocks ->
            case Advanced.run rawBlockParser rawBlocks of
                Ok value ->
                    case parseAllInlines value of
                        Ok parsedBlocks ->
                            Block.BlockQuote parsedBlocks
                                |> ParsedBlock

                        Err e ->
                            InlineProblem e

                Err error ->
                    InlineProblem (Parser.Problem (deadEndsToString error))

        IndentedCodeBlock codeBlockBody ->
            Block.CodeBlock { body = codeBlockBody, language = Nothing }
                |> ParsedBlock

        Table (Markdown.Table.Table header rows) ->
            let
                parseHeader { label, alignment } =
                    let
                        wrap parsedHeaderLabel =
                            { label = parsedHeaderLabel
                            , alignment = alignment
                            }
                    in
                    parseRawInline linkReferences wrap (UnparsedInlines label)
            in
            Block.Table (List.map parseHeader header) []
                |> ParsedBlock


parseRawInline : LinkReferenceDefinitions -> (List Inline -> a) -> UnparsedInlines -> a
parseRawInline linkReferences wrap unparsedInlines =
    unparsedInlines
        |> inlineParseHelper linkReferences
        |> wrap


plainLine : Parser RawBlock
plainLine =
    innerParagraphParser
        |. endOfLineOrFile


innerParagraphParser : Parser RawBlock
innerParagraphParser =
    Advanced.chompUntilEndOr "\n"
        |> Advanced.mapChompedString
            (\rawLine _ ->
                rawLine
                    |> UnparsedInlines
                    |> Body
            )


blockQuoteStarts : List (Parser ())
blockQuoteStarts =
    [ symbol (Advanced.Token ">" (Parser.Expecting ">"))
    , Advanced.backtrackable (symbol Token.space)
        |. oneOf
            [ symbol (Advanced.Token ">" (Parser.Expecting " >"))
            , symbol (Advanced.Token " >" (Parser.Expecting "  >"))
            , symbol (Advanced.Token "  >" (Parser.Expecting "   >"))
            ]
    ]


blockQuote : Parser RawBlock
blockQuote =
    succeed BlockQuote
        |. oneOf blockQuoteStarts
        |. oneOf [ symbol Token.space, succeed () ]
        |= Advanced.getChompedString (Advanced.chompUntilEndOr "\n")
        |. endOfLineOrFile


unorderedListBlock : Parser RawBlock
unorderedListBlock =
    let
        parseListItem unparsedListItem =
            case unparsedListItem of
                ListItem.TaskItem completion body ->
                    { body = UnparsedInlines body
                    , task =
                        (case completion of
                            ListItem.Complete ->
                                True

                            ListItem.Incomplete ->
                                False
                        )
                            |> Just
                    }

                ListItem.PlainItem body ->
                    { body = UnparsedInlines body
                    , task = Nothing
                    }
    in
    Markdown.UnorderedList.parser
        |> map (List.map parseListItem >> UnorderedListBlock)


orderedListBlock : Bool -> Parser RawBlock
orderedListBlock previousWasBody =
    Markdown.OrderedList.parser previousWasBody
        |> map (\( startingIndex, unparsedLines ) -> OrderedListBlock startingIndex (List.map UnparsedInlines unparsedLines))


blankLine : Parser RawBlock
blankLine =
    Advanced.backtrackable (chompWhile Helpers.isSpaceOrTab)
        |. symbol Token.newline
        |> map (\_ -> BlankLine)


htmlParser : Parser RawBlock
htmlParser =
    HtmlParser.html
        |> Advanced.andThen xmlNodeToHtmlNode


xmlNodeToHtmlNode : Node -> Parser RawBlock
xmlNodeToHtmlNode xmlNode =
    case xmlNode of
        HtmlParser.Text innerText ->
            Body (UnparsedInlines innerText)
                |> succeed

        HtmlParser.Element tag attributes children ->
            case nodesToBlocks children of
                Ok parsedChildren ->
                    Block.HtmlElement tag attributes parsedChildren
                        |> RawBlock.Html
                        |> succeed

                Err err ->
                    problem err

        Comment string ->
            Block.HtmlComment string
                |> RawBlock.Html
                |> succeed

        Cdata string ->
            Block.Cdata string
                |> RawBlock.Html
                |> succeed

        ProcessingInstruction string ->
            Block.ProcessingInstruction string
                |> RawBlock.Html
                |> succeed

        Declaration declarationType content ->
            Block.HtmlDeclaration declarationType content
                |> RawBlock.Html
                |> succeed


textNodeToBlocks : String -> List Block
textNodeToBlocks textNodeValue =
    parse textNodeValue
        |> Result.withDefault []


nodeToRawBlock : Node -> Block.Html Block
nodeToRawBlock node =
    case node of
        HtmlParser.Text innerText ->
            Block.HtmlComment "TODO this never happens, but use types to drop this case."

        HtmlParser.Element tag attributes children ->
            let
                parseChild child =
                    case child of
                        HtmlParser.Text text ->
                            textNodeToBlocks text

                        _ ->
                            [ nodeToRawBlock child |> Block.HtmlBlock ]
            in
            Block.HtmlElement tag
                attributes
                (List.concatMap parseChild children)

        Comment string ->
            Block.HtmlComment string

        Cdata string ->
            Block.Cdata string

        ProcessingInstruction string ->
            Block.ProcessingInstruction string

        Declaration declarationType content ->
            Block.HtmlDeclaration declarationType content


nodesToBlocks : List Node -> Result Parser.Problem (List Block)
nodesToBlocks children =
    nodesToBlocksHelp children []


nodesToBlocksHelp : List Node -> List Block -> Result Parser.Problem (List Block)
nodesToBlocksHelp remaining soFar =
    case remaining of
        node :: rest ->
            case childToBlocks node soFar of
                Ok newSoFar ->
                    nodesToBlocksHelp rest newSoFar

                Err e ->
                    Err e

        [] ->
            Ok (List.reverse soFar)


{-| Add the blocks from this node to the passed-in list of blocks
-}
childToBlocks : Node -> List Block -> Result Parser.Problem (List Block)
childToBlocks node blocks =
    case node of
        Element tag attributes children ->
            case nodesToBlocks children of
                Ok childrenAsBlocks ->
                    let
                        block =
                            Block.HtmlElement tag attributes childrenAsBlocks
                                |> Block.HtmlBlock
                    in
                    Ok (block :: blocks)

                Err err ->
                    Err err

        Text innerText ->
            case parse innerText of
                Ok value ->
                    Ok (List.reverse value ++ blocks)

                Err error ->
                    Err
                        (Parser.Expecting
                            (error
                                |> List.map deadEndToString
                                |> String.join "\n"
                            )
                        )

        Comment string ->
            Ok (Block.HtmlBlock (Block.HtmlComment string) :: blocks)

        Cdata string ->
            Ok (Block.HtmlBlock (Block.Cdata string) :: blocks)

        ProcessingInstruction string ->
            Ok (Block.HtmlBlock (Block.ProcessingInstruction string) :: blocks)

        Declaration declarationType content ->
            Ok (Block.HtmlBlock (Block.HtmlDeclaration declarationType content) :: blocks)


type alias LinkReferenceDefinitions =
    List ( String, { destination : String, title : Maybe String } )


type alias State =
    { linkReferenceDefinitions : LinkReferenceDefinitions
    , rawBlocks : List RawBlock
    }


addReference : State -> LinkReferenceDefinition -> State
addReference state linkRef =
    { linkReferenceDefinitions = linkRef :: state.linkReferenceDefinitions
    , rawBlocks = state.rawBlocks
    }


rawBlockParser : Parser State
rawBlockParser =
    loop
        { linkReferenceDefinitions = []
        , rawBlocks = []
        }
        stepRawBlock


parseAllInlines : State -> Result Parser.Problem (List Block)
parseAllInlines state =
    parseAllInlinesHelp state state.rawBlocks []


parseAllInlinesHelp : State -> List RawBlock -> List Block -> Result Parser.Problem (List Block)
parseAllInlinesHelp state rawBlocks parsedBlocks =
    case rawBlocks of
        rawBlock :: rest ->
            case parseInlines state.linkReferenceDefinitions rawBlock of
                ParsedBlock newParsedBlock ->
                    parseAllInlinesHelp state rest (newParsedBlock :: parsedBlocks)

                EmptyBlock ->
                    -- ignore empty blocks
                    parseAllInlinesHelp state rest parsedBlocks

                InlineProblem e ->
                    Err e

        [] ->
            Ok parsedBlocks


possiblyMergeBlocks : State -> RawBlock -> State
possiblyMergeBlocks state newRawBlock =
    { linkReferenceDefinitions = state.linkReferenceDefinitions
    , rawBlocks =
        case
            ( newRawBlock
            , state.rawBlocks
            )
        of
            ( CodeBlock block1, (CodeBlock block2) :: rest ) ->
                CodeBlock
                    { body = joinStringsPreserveAll block2.body block1.body
                    , language = Nothing
                    }
                    :: rest

            ( IndentedCodeBlock block1, (IndentedCodeBlock block2) :: rest ) ->
                IndentedCodeBlock (joinStringsPreserveAll block2 block1)
                    :: rest

            ( Body (UnparsedInlines body1), (BlockQuote body2) :: rest ) ->
                BlockQuote (joinRawStringsWith "\n" body2 body1)
                    :: rest

            ( BlockQuote body1, (BlockQuote body2) :: rest ) ->
                BlockQuote (joinStringsPreserveAll body2 body1)
                    :: rest

            ( Body (UnparsedInlines body1), (Body (UnparsedInlines body2)) :: rest ) ->
                Body (UnparsedInlines (joinRawStringsWith "\n" body2 body1))
                    :: rest

            _ ->
                newRawBlock :: state.rawBlocks
    }



-- RAW BLOCK PARSER


stepRawBlock : State -> Parser (Step State State)
stepRawBlock revStmts =
    -- Some blocks can't immediately follow a body
    case revStmts.rawBlocks of
        (Body _) :: _ ->
            oneOf whenPreviousWasBody
                |> map (\f -> f revStmts)

        _ ->
            oneOf whenPreviousWasNotBody
                |> map (\f -> f revStmts)



-- Note [Static Parser Structure]
--
-- For performance reasons, it is VERY IMPORTANT that `whenPreviousWasBody` and `whenPreviousWasNotBody`
-- defined as `var` in javascript (and not as a function taking any, even zero, arguments).
--
-- A `var` is defined once, then re-used for every raw block we parse. If they were functions, the parser
-- structure would need to be re-built for every raw block.
-- Because there are lists involved (in the `oneOf`s), that is expensive.
--
-- All my attempts so far to "DRY" this code below cause a degradation in performance.


whenPreviousWasBody : List (Parser (State -> Step State State))
whenPreviousWasBody =
    [ Helpers.endOfFile
        |> map (\_ revStmts -> Done revStmts)
    , parseAsParagraphInsteadOfHtmlBlock
        |> map (\block revStmts -> Loop (possiblyMergeBlocks revStmts block))
    , LinkReferenceDefinition.parser
        |> Advanced.backtrackable
        |> map (\reference revStmts -> Loop (addReference revStmts reference))
    , oneOf
        [ blankLine
        , blockQuote
        , Markdown.CodeBlock.parser |> Advanced.backtrackable |> map CodeBlock

        -- NOTE: indented block is not an option immediately after a Body
        , ThematicBreak.parser |> Advanced.backtrackable |> map (\_ -> ThematicBreak)
        , unorderedListBlock

        -- NOTE: the ordered list block changes its parsing rules when it's right after a Body
        , orderedListBlock True
        , heading |> Advanced.backtrackable
        , htmlParser

        -- TODO re-enable this once the table parser handles rows
        --, TableParser.parser |> Advanced.backtrackable |> map Table
        , plainLine
        ]
        |> map (\block revStmts -> Loop (possiblyMergeBlocks revStmts block))
    ]


whenPreviousWasNotBody : List (Parser (State -> Step State State))
whenPreviousWasNotBody =
    [ Helpers.endOfFile
        |> map (\_ revStmts -> Done revStmts)
    , parseAsParagraphInsteadOfHtmlBlock
        |> map (\block revStmts -> Loop (possiblyMergeBlocks revStmts block))
    , LinkReferenceDefinition.parser
        |> Advanced.backtrackable
        |> map (\reference revStmts -> Loop (addReference revStmts reference))
    , oneOf
        [ blankLine
        , blockQuote
        , Markdown.CodeBlock.parser |> Advanced.backtrackable |> map CodeBlock

        -- NOTE: indented block is an option after any non-Body block
        , indentedCodeBlock
        , ThematicBreak.parser |> Advanced.backtrackable |> map (\_ -> ThematicBreak)
        , unorderedListBlock

        -- NOTE: the ordered list block changes its parsing rules when it's right after a Body
        , orderedListBlock False
        , heading |> Advanced.backtrackable
        , htmlParser

        -- TODO re-enable this once the table parser handles rows
        --, TableParser.parser |> Advanced.backtrackable |> map Table
        , plainLine
        ]
        |> map (\block revStmts -> Loop (possiblyMergeBlocks revStmts block))
    ]


{-| HTML parsing is intentionally strict in `dillonkearns/elm-markdown`. Paragraphs are supposed to be forgiving.
This function checks to see if something might be an autolink that could be confused with an HTML block because
the line starts with `<`. But it's slightly more lenient, so that things like `<>` that aren't actually parsed as
autolinks are still parsed as paragraphs.
-}
parseAsParagraphInsteadOfHtmlBlock : Parser RawBlock
parseAsParagraphInsteadOfHtmlBlock =
    -- ^<[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\x00-\x20]*>
    token (Advanced.Token "<" (Parser.Expecting "<"))
        |. thisIsDefinitelyNotAnHtmlTag
        |. Advanced.chompUntilEndOr "\n"
        |. endOfLineOrFile
        |> Advanced.mapChompedString (\rawLine _ -> rawLine |> UnparsedInlines |> Body)
        |> Advanced.backtrackable


thisIsDefinitelyNotAnHtmlTag : Parser ()
thisIsDefinitelyNotAnHtmlTag =
    oneOf
        [ token (Advanced.Token " " (Parser.Expecting " "))
        , token (Advanced.Token ">" (Parser.Expecting ">"))
        , chompIf Char.isAlpha (Parser.Expecting "Alpha")
            |. chompWhile (\c -> Char.isAlphaNum c || c == '-')
            |. oneOf
                [ token (Advanced.Token ":" (Parser.Expecting ":"))
                , token (Advanced.Token "@" (Parser.Expecting "@"))
                , token (Advanced.Token "\\" (Parser.Expecting "\\"))
                , token (Advanced.Token "+" (Parser.Expecting "+"))
                , token (Advanced.Token "." (Parser.Expecting "."))
                ]
        ]


joinStringsPreserveAll : String -> String -> String
joinStringsPreserveAll string1 string2 =
    string1 ++ "\n" ++ string2


joinRawStringsWith : String -> String -> String -> String
joinRawStringsWith joinWith string1 string2 =
    case ( string1, string2 ) of
        ( "", _ ) ->
            string2

        ( _, "" ) ->
            string1

        _ ->
            string1 ++ joinWith ++ string2


exactlyFourSpaces : Parser ()
exactlyFourSpaces =
    oneOf
        [ symbol Token.tab
        , Advanced.backtrackable (symbol Token.space)
            |. oneOf
                [ Advanced.symbol (Advanced.Token "   " (Parser.ExpectingSymbol "Indentation"))
                , Advanced.symbol (Advanced.Token " \t" (Parser.ExpectingSymbol "Indentation"))
                , Advanced.symbol (Advanced.Token "  \t" (Parser.ExpectingSymbol "Indentation"))
                ]
        ]


indentedCodeBlock : Parser RawBlock
indentedCodeBlock =
    succeed IndentedCodeBlock
        |. exactlyFourSpaces
        |= getChompedString (Advanced.chompUntilEndOr "\n")
        |. endOfLineOrFile


heading : Parser RawBlock
heading =
    succeed Heading
        |. symbol Token.hash
        |= (getChompedString (chompWhile isHash)
                |> andThen
                    (\additionalHashes ->
                        let
                            level =
                                String.length additionalHashes + 1
                        in
                        if level >= 7 then
                            Advanced.problem (Parser.Expecting "heading with < 7 #'s")

                        else
                            succeed level
                    )
           )
        |= (Advanced.chompUntilEndOr "\n"
                |> Advanced.mapChompedString
                    (\headingText _ ->
                        headingText
                            |> String.trimLeft
                            |> dropTrailingHashes
                            |> UnparsedInlines
                    )
           )


isHash : Char -> Bool
isHash c =
    case c of
        '#' ->
            True

        _ ->
            False


dropTrailingHashes : String -> String
dropTrailingHashes headingString =
    if headingString |> String.endsWith "#" then
        String.dropRight 1 headingString
            |> String.trimRight
            |> dropTrailingHashes

    else
        headingString
