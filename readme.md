# Introduction

The module *xlsx* allows read and write access to .xlsx files.

> This fork replaces the dependency [lua-ziparchive](https://github.com/jjensen/lua-ziparchive) with [lua-zip](https://github.com/brimworks/lua-zip) and replaces [xmlize](https://github.com/jjensen/lua-xmlize) with [lua-expat](https://github.com/lunarmodules/luaexpat).

## Example Usage

### Reading

```lua
local XLSX = require('xlsx')
local workbook = XLSX.Workbook(filename)

local data
for _, sheet in ipairs(workbook.__sheets) do
    if sheet.name == "Sheet1" then
        data = sheet.data
    end
end
```

A worksheet is `{ name, columns, data }`. Row 1 of the sheet is the header, and becomes `columns`;
every row after it becomes an entry in `data`, keyed by column name.

### Writing

```lua
local XLSX = require('xlsx')

local sheet = {
    name = 'Stock',
    columns = { 'Part', 'Qty', 'Discontinued' },
    data = {
        { Part = 'Widget', Qty = 12, Discontinued = false },
        { Part = 'Gadget', Qty = 0,  Discontinued = true },
    }
}

---data expects an array of sheets
local data = { sheet }
XLSX.Write(filename, data)
```
> You can use the `LuaLS` typing system to help format. `data` is an array of `XlsxWorksheet`

Or build the workbook up first, which is also how a file that was read can be written back out:

```lua
local XLSX = require('xlsx')
local workbook = XLSX.NewWorkbook()
local columns = {
    'Part',
    'Qty'
}
local sheet = {
    { Part = 'Widget', Qty = 12},
    { Part = 'Gadget', Qty = 0}
}
workbook:AddWorksheet('Stock', columns, sheet)
workbook:Save(filename)
```

Cell values may be strings, numbers, booleans, or `nil` for a blank cell. `columns` is optional; when
it is left out the column names are taken from the data keys and sorted alphabetically.
