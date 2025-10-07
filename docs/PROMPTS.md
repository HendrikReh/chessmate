# LLM Prompts for Chess Analysis

This document contains useful prompts for using large language models (GPT-4, GPT-5, Claude, etc.) to perform chess-related transformations and analysis tasks.

---

## Pawn Structure Extraction

### Purpose

Extract pawn structure from a complete chess position (FEN string) by removing all pieces except pawns. This is useful for:

- Analyzing pawn structure patterns independently of piece placement
- Comparing pawn formations across different games
- Generating training data for pawn structure embeddings
- Identifying common pawn structures (isolated pawns, pawn chains, passed pawns, etc.)

### Prompt Template

```
Strip all pieces besides the pawns from '<FEN_STRING>' and show me the resulting FEN.
```

### Example Usage

**Input:**
```
Strip all pieces besides the pawns from 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1' and show me the resulting FEN.
```

**Expected Output:**
```
8/pppppppp/8/8/3P4/8/PPP1PPPP/8 b - d3 0 1
```

**Explanation:**
- `rnbqkbnr` → `8` (rank 8: all pieces removed, 8 empty squares)
- `pppppppp` → `pppppppp` (rank 7: black pawns remain)
- Rank 6-5: empty (no pawns)
- `3P4` → `3P4` (rank 4: white pawn on d4)
- Rank 3: empty
- `PPP1PPPP` → `PPP1PPPP` (rank 2: white pawns)
- `RNBQKBNR` → `8` (rank 1: all pieces removed)
- Castling rights cleared (`KQkq` → `-`) since kings are removed
- En passant square retained (`d3`)

### Integration with Chessmate

This technique can be used to:

1. **Generate pawn structure embeddings**: Create separate embeddings for pawn structures to enhance search for "games with similar pawn structures"

2. **Augment position metadata**: Store pawn structure FEN alongside full position FEN in the database

3. **Enable pawn-specific queries**: Search for "French Defense with isolated queen's pawn" by matching pawn structure patterns

4. **Preprocessing pipeline**: Add pawn extraction step in `lib/chess/fen.ml` or during ingestion

### Implementation Example

To integrate this into Chessmate, you could:

```ocaml
(* lib/chess/fen.ml *)

let strip_pieces_except_pawns fen =
  (* Parse FEN placement string *)
  let parts = String.split fen ~on:' ' in
  match parts with
  | placement :: rest ->
      (* Strip non-pawn pieces from each rank *)
      let pawn_only_placement =
        placement
        |> String.to_list
        |> List.map ~f:(fun ch ->
             match ch with
             | 'p' | 'P' | '/' -> ch  (* Keep pawns and rank separators *)
             | _ when Char.is_digit ch -> ch  (* Keep empty square counts *)
             | _ -> '1')  (* Replace pieces with 1 empty square *)
        |> String.of_char_list
        |> compress_empty_squares  (* Merge adjacent digits *)
      in
      (* Reconstruct FEN with pawn-only placement *)
      (* Clear castling rights since kings are removed *)
      String.concat ~sep:" " (pawn_only_placement :: rest |> update_castling)
  | _ -> fen

let compress_empty_squares placement =
  (* Helper to merge '1' '1' '1' → '3' *)
  ...
```

---

## Other Useful Chess Prompts

### 1. ECO Code Classification

**Purpose**: Classify opening positions by ECO code when header information is missing.

**Prompt:**
```
Analyze this chess position (FEN) and identify the opening's ECO code: '<FEN_STRING>'. Provide the ECO code (e.g., E97) and opening name.
```

### 2. Position Description Generation

**Purpose**: Generate natural language descriptions of positions for embedding or annotation.

**Prompt:**
```
Describe the following chess position in 2-3 sentences, focusing on pawn structure, piece activity, and strategic themes: '<FEN_STRING>'.
```

### 3. Tactical Theme Detection

**Purpose**: Identify tactical motifs present in a position.

**Prompt:**
```
Analyze this chess position (FEN) for tactical themes such as pins, forks, skewers, discovered attacks, or sacrifices: '<FEN_STRING>'. List all identified themes.
```

### 4. Game Phase Classification

**Purpose**: Determine whether a position is opening, middlegame, or endgame.

**Prompt:**
```
Given this chess position (FEN): '<FEN_STRING>', classify the game phase as opening, middlegame, or endgame. Consider piece count, king safety, and pawn structure.
```

**Integration Note**: This could augment `lib/chess/position_features.ml` for automatic phase detection.

---

## Best Practices

1. **Validation**: Always validate LLM output against known positions before integrating into production
2. **Caching**: Cache LLM-generated analysis to avoid redundant API calls
3. **Batch Processing**: Process multiple positions in a single API call when possible
4. **Fallback Logic**: Implement deterministic fallbacks for critical features (e.g., phase detection by material count)
5. **Cost Management**: Use cheaper models (GPT-4o-mini, Claude Haiku) for bulk processing

---

## GPT-5 Chess Understanding

GPT-5 demonstrates strong chess knowledge and asks for clarification when faced with ambiguous opening names. For example:

**User Query:**
```
Show me the ECO ranges for the following chess openings: King's Indian Defense, Tarrasch, QGD
```

**GPT-5 Response:**
```
Could you please clarify what you mean by "Tarrasch"? Are you referring to:
1. The Tarrasch Defense (a line in the Queen's Gambit Declined),
2. The Tarrasch Variation of the French Defense,
3. Or another opening entirely?

Let me know so I can give you the correct ECO code ranges.
```

**Key Observations:**

1. **Contextual Awareness**: GPT-5 recognizes that "Tarrasch" is ambiguous without further context
2. **Domain Knowledge**: Knows specific variations (Tarrasch Defense in QGD vs. Tarrasch in French)
3. **User Experience**: Asks for clarification rather than guessing, preventing incorrect information
4. **Professional Tone**: Provides numbered options for easy selection

**Implications for Chessmate:**

- GPT-5 can be reliably used for opening classification and ECO code mapping
- Consider using GPT-5 for query expansion: "Show me Tarrasch games" → prompt user to disambiguate
- Can assist with cleaning ambiguous opening names in ingested PGN files
- Suitable for augmenting the opening catalogue in `lib/chess/openings.ml` with additional synonyms

**Recommendation**: When building LLM-assisted features, leverage GPT-5's ability to handle ambiguity and provide clarifying questions rather than implementing complex disambiguation logic manually.

---

## Future Enhancements

Potential LLM-assisted features for Chessmate:

- **Automatic annotation generation**: "Kasparov sacrifices the exchange for long-term compensation..."
- **Query expansion**: User asks "attacking games" → LLM expands to themes: king_attack, sacrifice, tactical
- **Opening repertoire suggestions**: "Based on your database, recommend underplayed lines in the Najdorf"
- **Position comparison**: "How similar is this Sicilian to the famous Kasparov-Topalov 1999 game?"

---

## Related Documentation

- [Chessmate for Dummies](CHESSMATE_FOR_DUMMIES.md) - Complete ingestion and search flow
- [Architecture](ARCHITECTURE.md) - System design and components
- [Developer Handbook](DEVELOPER.md) - Contributing and coding standards
