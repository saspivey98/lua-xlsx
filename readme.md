# Introduction

The module *xlsx* allows read access to .xlsx files.

> This fork replaces the dependency [lua-ziparchive](https://github.com/jjensen/lua-ziparchive) with [lua-zip](https://github.com/brimworks/lua-zip), and also includes the [`xmlize`](https://github.com/jjensen/lua-xmlize) dependency.

## Example

```lua
local xlsx = require('xlsx')
local workbook = xlsx.Workbook(filename)
```

## TODO

Make a luarock of this package; must check for dependency `lua-zip`
