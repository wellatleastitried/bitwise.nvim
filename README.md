# bitwise-visualizer.nvim

Interactive, non-destructive visualization of bitwise expressions inside Neovim.

Put your cursor on a bitwise expression and see exactly what the bits do:

```text
  0000 1010  (10)
& 0000 1100  (12)
  ─────────
  0000 1000  (8)

int x = 10 & 12;
```

Expressions are found with **Tree-sitter** (never regex), evaluated with an
exact tri-state bit engine, and drawn with **extmarks and virtual lines**. Your
buffer is never modified.

---

## Table of contents

1. [What it does](#what-it-does)
2. [Installation](#installation)
3. [Examples](#examples)
4. [Configuration](#configuration)
5. [Supported languages and operators](#supported-languages-and-operators)
6. [Static versus runtime values](#static-versus-runtime-values)
7. [Bit-width semantics](#bit-width-semantics)
8. [Commands and API](#commands-and-api)
9. [Performance](#performance)
10. [Known limitations](#known-limitations)

---

## What it does

* Detects the bitwise expression under (or around) the cursor using Tree-sitter.
* Evaluates it exactly, including 64-bit values, using a bit-array engine rather
  than Lua numbers, so results are never distorted by floating point.
* Renders operands, a separator and the result aligned by bit position, with the
  bits that actually drive the result highlighted.
* Tracks *what is knowable at compile time*. Runtime operands are shown as `?`
  bits, and known bits are still propagated (`flags & 0x0F` really does have a
  zero upper nibble).
* Updates as the cursor moves and the buffer changes, and never leaves stale
  decorations behind.

Non-goals: it is not a debugger and does not perform dataflow analysis. It never
invents a runtime value.

## Installation

Requires **Neovim 0.10+** and a Tree-sitter parser for the language you are
editing.

### lazy.nvim

```lua
{
  "wellatleastitried/bitwise-visualizer.nvim",
  main = "bitwise-visualizer",
  event = "VeryLazy",
  opts = {
    -- everything is optional; see the configuration reference
    width = "auto",
  },
}
```

### packer.nvim

```lua
use({
  "wellatleastitried/bitwise-visualizer.nvim",
  config = function()
    require("bitwise-visualizer").setup({})
  end,
})
```

### vim-plug

```vim
Plug 'wellatleastitried/bitwise-visualizer.nvim'
" optional:
lua require("bitwise-visualizer").setup({})
```

### mini.deps / paq / manual

Clone the repository into your `runtimepath`. Calling `setup()` is optional.
the plugin loads with working defaults on its own.

Verify the installation with `:checkhealth bitwise-visualizer`.

## Examples

All output below is produced by the plugin itself.

**Constant folding**: `int x = 10 & 12;`

```text
  0000 1010  (10)
& 0000 1100  (12)
  ─────────
  0000 1000  (8)
```

**Partially known values**: `x = flags & 0x0F;`

```text
  ???? ????  flags
& 0000 1111  0x0F  (15)
  ─────────
  0000 ????  flags & 0x0F
  32-bit signed value, showing the low 8 bits
```

**Shifts**: `x = 10 << 2;`

```text
   0000 1010  (10)
<< 2
   ─────────
   0010 1000  (40)
```

**Arithmetic vs logical shift**: `x = -8 >> 1;` in C

```text
   1111 1000  (-8)
>> 1 (arithmetic)
   ─────────
   1111 1100  (-4)
```

**Unary NOT**: `x = ~10;`

```text
~ 0000 1010  (10)
  ─────────
  1111 0101  (-11)
```

**Nested expressions**: `x = (10 & 12) ^ 3;` with the cursor on `^`

```text
  0000 1000  (10 & 12)  (8)
^ 0000 0011  (3)
  ─────────
  0000 1011  (11)
```

Placing the cursor on the inner `&` instead visualizes just `10 & 12`.

> Screenshots/GIFs: run the examples above in your own colorscheme. The bits
> that drive the result are highlighted with `BitwiseVisualizerActive`, unknown
> bits with `BitwiseVisualizerUnknown`.

## Configuration

`setup()` is optional. Misspelled option names are reported rather than
silently ignored. These are the defaults:

```lua
require("bitwise-visualizer").setup({
  -- Master switch.
  enabled = true,

  -- Follow the cursor automatically. When false, use :BitwiseVisualizerShow.
  auto = true,

  -- "auto" | 8 | 16 | 32 | 64
  width = "auto",

  -- Candidate widths used when width = "auto".
  display_widths = { 8, 16, 32, 64 },

  -- Insert a space every N bits (0 disables grouping).
  group_bits = 4,

  show_decimal = true,        -- append (42) style annotations
  show_hex = false,           -- append 0x2A style annotations
  show_labels = true,         -- show the operand source text
  show_unknown = true,        -- render expressions with runtime operands
  show_fully_unknown = false, -- render even when nothing at all is known
  show_notes = true,          -- show caveats (overflow, undefined shifts, ...)

  -- Resolve identifiers that provably hold a constant (see "Constant
  -- resolution" below). Set to false to treat every identifier as runtime.
  resolve_identifiers = true,

  -- Analyse languages that have no dedicated adapter structurally.
  generic_fallback = true,

  -- Set an operator to false to ignore it.
  operators = {
    ["&"] = true, ["|"] = true, ["^"] = true, ["~"] = true,
    ["<<"] = true, [">>"] = true, [">>>"] = true, ["&^"] = true,
    ["-"] = true, ["+"] = true,
  },

  -- "expression": activate anywhere inside the expression
  -- "operator":   activate only when the cursor is on the operator token
  trigger = "expression",

  -- Visualize only the subexpression whose operator is under the cursor.
  subexpression = true,

  -- "above" | "below" | "eol"
  position = "above",

  -- Rendering backend; see renderer.register_backend().
  renderer = "virt_lines",

  update = {
    debounce = 50,      -- ms
    in_insert = false,  -- update while in insert mode
    events = {
      "CursorMoved", "CursorMovedI",
      "TextChanged", "TextChangedI",
      "BufEnter",
    },
  },

  max_nodes = 32,            -- maximum expression complexity
  max_line_length = 500,     -- skip very long lines
  max_buffer_lines = 100000,

  disabled_filetypes = { "help", "text", "markdown", "TelescopePrompt" },

  highlights = {
    one       = "BitwiseVisualizerOne",
    zero      = "BitwiseVisualizerZero",
    unknown   = "BitwiseVisualizerUnknown",
    active    = "BitwiseVisualizerActive",
    separator = "BitwiseVisualizerSeparator",
    operator  = "BitwiseVisualizerOperator",
    label     = "BitwiseVisualizerLabel",
    value     = "BitwiseVisualizerValue",
    note      = "BitwiseVisualizerNote",
    result    = "BitwiseVisualizerResult",
  },
})
```

### Highlight groups

Every group is defined with `default = true` and linked to a standard group, so
colorschemes win and you can override any of them:

| Group | Linked to | Meaning |
| --- | --- | --- |
| `BitwiseVisualizerOne` | `String` | a set bit |
| `BitwiseVisualizerZero` | `Comment` | a clear bit |
| `BitwiseVisualizerUnknown` | `DiagnosticWarn` | a runtime (`?`) bit |
| `BitwiseVisualizerActive` | `DiagnosticOk` | a bit that drives the result |
| `BitwiseVisualizerSeparator` | `NonText` | the rule between operands and result |
| `BitwiseVisualizerOperator` | `Operator` | the operator column |
| `BitwiseVisualizerLabel` | `Identifier` | operand source text |
| `BitwiseVisualizerValue` | `Number` | decimal/hex annotations |
| `BitwiseVisualizerNote` | `Comment` | caveats |

```lua
vim.api.nvim_set_hl(0, "BitwiseVisualizerActive", { fg = "#ff9e64", bold = true })
```

## Supported languages and operators

| Language | Semantics highlights |
| --- | --- |
| C, C++, Objective-C, CUDA | 32-bit `int` by default, `u`/`l`/`ll` suffixes, over-wide shifts are undefined |
| Rust | `!` is bitwise NOT; `u8`/`i64`/... suffixes set width and signedness |
| Go | unary `^` is NOT, `&^` is AND-NOT, 64-bit `int`, shifts saturate |
| Java | `>>>`, shift counts masked, `L` suffix widens to 64 bits |
| JavaScript / TypeScript / TSX | operands coerced to 32-bit signed, `>>>`, BigInt declined |
| Python | arbitrary precision; the width is a display convention |
| Lua | binary `~` is XOR, unary `~` is NOT, `>>` is logical, 64-bit |

Operators: `&`, `|`, `^`, `~`, `<<`, `>>`, plus `>>>` (Java/JS) and `&^` (Go).
Unary `-` and `+` are understood so that `-8 >> 1` works, and `+`, `-`, `*` are
constant-folded so that operands such as `(y + 5) & 0xF` show a real value.
Arithmetic never triggers a visualization on its own.

### Any other language

Languages without a dedicated adapter are analysed **structurally**
(`generic_fallback = true`, the default): a node is a bitwise operation when it
has two operands and an operator token that reads as one, whatever the grammar
calls its node types. That covers essentially every infix language Tree-sitter
can parse -- Ruby, Perl, PHP, shell arithmetic, Ada, VHDL, Verilog, Zig,
Nim, D, Odin -- including their integer syntaxes:

| Syntax | Example |
| --- | --- |
| C family | `0xFF`, `0b1010`, `0o17`, `255u8` |
| Ada / VHDL | `16#FF#`, `2#1010#` |
| Verilog | `8'hFF`, `4'b1010` |
| Pascal / assembly | `$FF`, `%1010` |
| Lisp | `#xFF`, `#b1010` |
| BASIC | `&HFF` |

Unambiguously bitwise word operators (`band`, `bor`, `bxor`, `bitand`, `bnot`,
`shl`, `shr`, `sll`, `srl`, `asr`, ...) are recognised too. `and`, `or`, `xor`
and `not` are deliberately **not**: they are boolean in most languages, so
guessing there would print a confidently wrong result.

Generic analysis assumes 64-bit signed semantics and says so in a note, and
over-wide shifts degrade to unknown rather than guessing. Ambiguous literals --
notably a leading zero, which is octal in C and decimal elsewhere -- are refused
instead of guessed.

Non-infix languages (Forth, APL, Lisp-style prefix forms) never match, and the
plugin stays silent. Set `generic_fallback = false` to restrict the plugin to
the adapters listed above.

Adding a language is a single table in `lua/bitwise-visualizer/languages/`
describing its node types, operator tokens, literal syntax and integer
semantics. Adding an operator is one entry in `evaluator.binary_ops`. Both can
be done from your own config:

```lua
require("bitwise-visualizer.languages").register({
  name = "mylang",
  nodes = {
    binary = { binary_expression = true },
    unary = { unary_expression = true },
    paren = { parenthesized_expression = true },
    literal = { integer_literal = true },
  },
  binary_operators = { ["&"] = true },
  unary_operators = { ["~"] = "~" },
  parse_literal = function(text)
    return require("bitwise-visualizer.languages.util").scan_integer(text, {})
  end,
  semantics = { default_width = 32, default_signed = true },
})
```

## Static versus runtime values

The evaluator works on tri-state bits: `0`, `1` and `?`. Every value is
classified as:

| Classification | Meaning | Example |
| --- | --- | --- |
| **known** | every bit is determined at compile time | `10 & 12` |
| **partial** | some bits are determined | `flags & 0x0F` |
| **unknown** | nothing is determined | `foo() ^ bar()` |

Propagation follows the algebra of each operator: `0 & ? = 0`, `1 | ? = 1`,
`? ^ x = ?`. That is why `flags & 0x0F` correctly shows a zero upper nibble
while the lower nibble stays unknown.

The plugin never invents a runtime value. When semantics cannot be determined
safely (undefined shift, unparsable literal, unsupported operator) the result
degrades to `?` bits plus a note, or the visualization is suppressed entirely.

Fully unknown expressions are hidden by default (`show_fully_unknown = false`)
because they carry no information beyond the shape of the operation; set it to
`true` if you want them anyway. `show_unknown = false` suppresses anything that
is not fully known.

### Constant resolution

Identifiers are not automatically runtime values. When
`resolve_identifiers = true` (the default) the plugin reads the syntax tree and
resolves a name only when the tree *proves* its value:

```c
int y = 10;
int z = gety();
int a = y | z;   //  0000 1010  y  (10)
                 // |???? ????  z
                 //  ---------
                 //  ???? 1?1?  y | z
```

A name resolves only if **all** of these hold:

* the nearest enclosing scope that mentions it contains exactly one write;
* that write is an initialiser or a plain `=` assignment with a value;
* the write happens before the use;
* the write is *visible* from the use -- not inside a branch, loop or block the
  use is not itself inside;
* the name is never mutated (`y |= 1`, `y++`) or address-taken (`&y`), is not a
  parameter or pattern binding, and is not a loop target.

Arithmetic in the resolved value is folded, so `int y = 10; int a = y + 5;`
makes `a ^ z` show `a` as `0000 1111`.

In a language analysed by the generic fallback the scoping rules are unknown, so
resolution is stricter still: only a write at the same nesting level as the use
is trusted.

Anything else -- reassignment, shadowing, conditional assignment
(`if (c) { y = 3; }`), loop variables, multiple assignment, pointers, function
parameters, struct fields -- stays `?`. C `#define` constants are
resolved too, and a resolved value may itself be an expression (`int y = 1 << 3`).

This is deliberately conservative: the plugin would rather show `?` than a
value that a human reader could disprove.

## Bit-width semantics

* `width = "auto"` evaluates using the language's natural integer width (32 for
  C/Rust/Java/JS, 64 for Go/Lua/Python), promoted by literal suffixes such as
  `1ULL` or `255u8`. The *display* then shrinks to the smallest of
  `display_widths` that hides nothing but redundant sign/zero extension. When
  unknown high bits are hidden, a note says so.
* `width = 8 | 16 | 32 | 64` forces both evaluation and display.
* Signedness comes from the language and from literal suffixes; a single
  unsigned literal makes the expression unsigned, mirroring C's usual arithmetic
  conversions.
* `>>` is arithmetic on signed values in C/Rust/Go/Java, and logical in Lua.
  Java and JavaScript additionally provide `>>>`.
* Shifts of at least the operand width are handled per language: **undefined**
  (C, C++, Rust, shown as fully unknown), **masked** (Java, JavaScript) or
  **saturating** (Go, Python, Lua).
* Arithmetic is performed on bit arrays, never on Lua numbers, so 64-bit values
  such as `18446744073709551615` are exact.
* Literals that do not fit the effective width produce an explicit overflow note
  instead of a silently truncated result.

## Commands and API

| Command | Lua | Description |
| --- | --- | --- |
| `:BitwiseVisualizerEnable` | `require("bitwise-visualizer").enable()` | enable, and turn cursor-following back on |
| `:BitwiseVisualizerDisable` | `.disable()` | disable, turn cursor-following off, and clear |
| `:BitwiseVisualizerToggle` | `.toggle()` | toggle between the above two states, returns the new state |
| `:BitwiseVisualizerShow` | `.show()` | one-shot visualization at the cursor |
| `:BitwiseVisualizerShow!` | `.render_text()` | echo it as plain text |
| `:BitwiseVisualizerHide` | `.hide()` | clear the current buffer |
| `:BitwiseVisualizerWidth {auto\|8\|16\|32\|64}` | `.configure({ width = 8 })` | change the width |
| `:BitwiseVisualizerStatus` | `.status()` | diagnostics |
| `:BitwiseVisualizerReset` | `require("bitwise-visualizer.config").reset()` | restore defaults |

`enable()`/`disable()`/`toggle()` always move both `enabled` and `auto`
together, so they can never disagree: `enable()` sets both to `true`,
`disable()` sets both to `false`. If you want the visualization enabled but
manual-only (no automatic cursor-following), set `auto = false` yourself
(in `setup()` or with `configure({ auto = false })`) and drive it with
`show()`/`hide()`, which work regardless of `enabled`/`auto`.

Additional Lua entry points:

```lua
local bv = require("bitwise-visualizer")

bv.setup(opts)                       -- configure (optional)
bv.configure(patch)                  -- change configuration at runtime and redraw
bv.refresh()                         -- recompute and redraw now
bv.analyze(buf, row, col, overrides) -- inspect without drawing anything
bv.render_text()                     -- the visualization as plain strings
bv.is_enabled()
bv.status()

require("bitwise-visualizer.renderer").register_backend("my_mode", fn)
```

Suggested mapping:

```lua
vim.keymap.set("n", "<leader>bv", "<Cmd>BitwiseVisualizerToggle<CR>")
```

## Performance

* Only the smallest relevant Tree-sitter node is inspected; the buffer is never
  re-parsed or scanned as a whole.
* Cursor-driven updates are debounced (`update.debounce`, 50 ms default).
* Analysis results are memoized per buffer, keyed on `changedtick`, the selected
  expression range and the configuration version.
* The renderer compares a signature of what it is about to draw and skips
  identical redraws, so moving within one expression costs nothing.
* Exactly **one extmark** per buffer is ever alive; it is cleared on `BufLeave`,
  `WinLeave`, `InsertEnter` (unless `update.in_insert`) and whenever no
  expression applies.
* Guards for pathological input: `max_nodes`, `max_line_length`,
  `max_buffer_lines`, `disabled_filetypes`.

The test suite asserts that 50 refreshes in a 20,000-line C file complete in
under a second.

## Known limitations

* Constant resolution is syntactic, not a dataflow analysis: values that depend
  on control flow, function calls, pointers or fields stay unknown.
* `enum` members, `constexpr` functions and imported/module-level constants from
  other files are not resolved.
* Macros are read syntactically: one defined after the use, `#undef`d, or
  written inside `#if`/`#ifdef` is refused rather than guessed.
* In shell, a name that appears as a bare command argument is refused, because
  `read y` and `let y=20` are indistinguishable from `echo y` to a parser.
* Division and remainder are not folded: `/` truncates in C and floors in
  Python, so the operand stays unknown rather than risk the wrong value.
* Generic (adapter-less) analysis assumes 64-bit signed semantics; a language
  with different widths or shift rules needs a small adapter for exact results.
* C++ digit separators are handled, but user-defined literals are not.
* JavaScript `BigInt` literals are declined rather than approximated.
* Python's arbitrary precision integers are shown at a fixed display width; when
  a shift grows past that window the decimal is omitted rather than truncated.
* Rust integer types are inferred from suffixes only; an unsuffixed literal is
  assumed to be `i32`.
* C/C++/Java character literals (`'A'`, `'\n'`, `'\x41'`) are read as integers;
  in other languages they are treated as unknown operands.
* Languages whose bitwise operations are method calls or infix words (Kotlin's
  `shl`, C#'s `BitOperations`) are not supported.
* Nothing is shown inside syntactically broken code. This is by design.

## License
MIT. See [LICENSE](LICENSE).
