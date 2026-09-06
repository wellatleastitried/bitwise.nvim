# Testing locally

```bash
make test   # full suite: pure-Lua core + headless Neovim
```

## Try it inside your own Neovim config

Plugin managers such as lazy.nvim rebuild `runtimepath` at startup, so
`nvim --cmd "set rtp+=..."` is silently discarded. Add the plugin *after*
your config has loaded instead:

```bash
cd /path/to/bitwise.nvim
printf 'int x = 10 & 12;\n' > /tmp/demo.c

nvim -c "set rtp+=$PWD" \
     -c "runtime! plugin/bitwise-visualizer.lua" \
     -c "lua require('bitwise-visualizer').refresh()" \
     /tmp/demo.c
```

Put the cursor on the `&` (or anywhere in `10 & 12`) and the visualization
appears above the line. Handy alias:

```bash
alias nvim-bitwise='nvim -c "set rtp+=/path/to/bitwise.nvim" -c "runtime! plugin/bitwise-visualizer.lua" -c "lua require(\"bitwise-visualizer\").refresh()"'
```

To pass options, `:lua require("bitwise-visualizer").setup({ width = 16 })`
after startup, or use a lazy.nvim local spec: `{ dir = "/path/to/bitwise.nvim", opts = {} }`.

Then check `:checkhealth bitwise-visualizer`, `:BitwiseVisualizerToggle`, and
that leaving the expression removes the visualization.

## Clean room (no user config)

```bash
nvim -u NONE --cmd "set rtp+=$PWD" -c "runtime! plugin/bitwise-visualizer.lua" -c "filetype plugin on" /tmp/demo.c
```
