--[[
* lua-xlsx
*
* Based on the original implementation by Josh Jensen.
* Modified to be compatible with Lua 5.3 and lib-zip by Simon Spivey.
*
--]]

---The module lua-xlsx allows read and write access to .xlsx files.
---@class lua-xlsx
local lib = {}

---return file info; for embedded purposes
---@private
function lib:INFO(_)
    local info = {}
    for k in pairs(self) do table.insert(info, k) end
    return {
        version = {
            major = 0,
            minor = 2,
            revision = 0,
        },
        library = {
            modulename = "lua-xlsx"
        },
        dependencies = {
            "lua-zip",
            "luaexpat"
        },
        functions = info
    }
end

local ZIP = require('brimworks.zip')
local lxp = require('lxp')

local colRowPattern = "([a-zA-Z]*)(%d*)"
local A_BYTE = string.byte('A')

local xmlHeader = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
local nsMain = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
local nsRelationships = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
local nsPackageRelationships = 'http://schemas.openxmlformats.org/package/2006/relationships'
local nsContentTypes = 'http://schemas.openxmlformats.org/package/2006/content-types'
local spreadsheetml = 'application/vnd.openxmlformats-officedocument.spreadsheetml'

local xmlEscapes = {
    ['&'] = '&amp;',
    ['<'] = '&lt;',
    ['>'] = '&gt;',
    ['"'] = '&quot;',
    ["'"] = '&apos;',
}

---Excel rejects these outright, so they are caught before writing rather than producing a workbook
---it refuses to open
local sheetNameInvalidPattern = "[%[%]%*/\\%?:]"
local sheetNameMaxLength = 31

--[[
Builds the same "@" / "#" node shape used throughout this file:
    node['@']  -> table of attributes (always present, may be empty)
    node['#']  -> either a string (leaf text content), or a table
                  mapping child tag name -> array of child nodes
--]]
local function _xlsx_parsexml(data)
    local root = {}
    local stack = { root }

    local callbacks = {}

    function callbacks.StartElement(_, name, attrs)
        local cleanAttrs = {}
        for k, v in pairs(attrs) do
            if type(k) == 'string' then
                cleanAttrs[k] = v
            end
        end

        local node = { ['@'] = cleanAttrs }

        local parent = stack[#stack]
        if type(parent['#']) ~= 'table' then
            parent['#'] = {}
        end
        local siblings = parent['#'][name]
        if not siblings then
            siblings = {}
            parent['#'][name] = siblings
        end
        siblings[#siblings + 1] = node

        stack[#stack + 1] = node
    end

    function callbacks.EndElement(_, name)
        local node = table.remove(stack)
        if node['#'] == nil then
            node['#'] = ''
        end
    end

    function callbacks.CharacterData(_, text)
        if not text or text == '' then return end
        local current = stack[#stack]
        if type(current['#']) == 'table' then
            return
        end
        current['#'] = (current['#'] or '') .. text
    end

    local parser = lxp.new(callbacks)
    local ok, err, line, col = parser:parse(data)
    if ok then
        ok, err, line, col = parser:parse()
    end
    parser:close()

    if not ok then
        error(("XML parse error: %s (line %s, col %s)"):format(tostring(err), tostring(line), tostring(col)))
    end

    return root['#']
end

local function _xlsx_readdocument(tbl, documentName)
    local xlsx = ZIP.open(tbl.filename)
    local file = xlsx:open(documentName)
    if not file then
        xlsx:close()
        return
    end

    local buffer
    local stat = xlsx:stat(documentName)
    if stat and stat.size and stat.size > 0 then
        buffer = file:read(stat.size)
    else
        ---this is original logic, which I presume was due to a limitation of the previous xml reader;
        ---keeping this chunk as a fallback just in case
        local chunks = {}
        while true do
            local chunk = file:read(8192)
            if not chunk or chunk == '' then break end
            chunks[#chunks + 1] = chunk
        end
        buffer = table.concat(chunks)
    end

    xlsx:close(file)

    if not buffer or buffer == '' then return end

    return _xlsx_parsexml(buffer)
end

local function _xlsx_loadsheet(workbook, id, name)
    local sheetDoc = _xlsx_readdocument(workbook, ("xl/worksheets/sheet%d.xml"):format(id))
    local data = {}
    local columns = {}

    local sheetData = sheetDoc and sheetDoc.worksheet[1]['#'].sheetData
    local rowNodes = sheetData and sheetData[1]['#'].row

    if rowNodes then
        local headers = {}
        local dataRowIndex = 0

        for rowIdx, rowNode in ipairs(rowNodes) do
            local rowValues = {}

            if rowNode['#'].c then
                for _, columnNode in ipairs(rowNode['#'].c) do
                    local cellId = columnNode['@'].r
                    local colLetters = cellId and cellId:match(colRowPattern)
                    local colNum = 0
                    if colLetters and colLetters ~= '' then
                        for index = 1, #colLetters do
                            colNum = colNum * 26 + (colLetters:byte(index) - A_BYTE + 1)
                        end
                    end

                    local colType = columnNode['@'].t
                    local value

                    if columnNode['#'].v then
                        value = columnNode['#'].v[1]['#']
                        if colType == 's' then
                            value = workbook.sharedStrings[tonumber(value) + 1]
                        elseif colType == 'b' then
                            value = (value == '1')
                        elseif colType ~= 'str' then
                            value = tonumber(value)
                        end
                    end

                    rowValues[colNum] = value
                end
            end

            if rowIdx == 1 then
                local colNums = {}
                for colNum, value in pairs(rowValues) do
                    headers[colNum] = (value ~= nil and value ~= '') and tostring(value) or ('Column' .. colNum)
                    colNums[#colNums + 1] = colNum
                end
                ---pairs() has no ordering, so the header names are replayed by column position; the
                ---writer needs that order to put the columns back where they came from
                table.sort(colNums)
                for index, colNum in ipairs(colNums) do
                    columns[index] = headers[colNum]
                end
            else
                local record = {}
                for colNum, value in pairs(rowValues) do
                    record[headers[colNum] or ('Column' .. colNum)] = value
                end
                dataRowIndex = dataRowIndex + 1
                data[dataRowIndex] = record
            end
        end
    end

    return { name = name, columns = columns, data = data }
end


---XML 1.0 only permits tab, newline and carriage return out of the control characters; the rest are
---dropped because a cell has no way to carry them
local function _xlsx_escapexml(text)
    local escaped = tostring(text):gsub('[&<>"\']', xmlEscapes)
    return (escaped:gsub('%c', function(control)
        if control == '\t' or control == '\n' or control == '\r' then return control end
        return ''
    end))
end

---1 -> "A", 26 -> "Z", 27 -> "AA"; the inverse of the colNum maths in _xlsx_loadsheet
local function _xlsx_columnname(colNum)
    local letters = {}
    while colNum > 0 do
        local remainder = (colNum - 1) % 26
        table.insert(letters, 1, string.char(A_BYTE + remainder))
        colNum = math.floor((colNum - 1 - remainder) / 26)
    end
    return table.concat(letters)
end

--[[
Serialises a number the way a spreadsheet expects it: no exponent-mangled integers, no "1.0" for
whole numbers, and enough digits that tonumber() hands back the value that went in.
--]]
local function _xlsx_formatnumber(value)
    if value ~= value or value == math.huge or value == -math.huge then
        error(("cannot write %s to a cell; .xlsx has no representation for it"):format(tostring(value)))
    end

    local isInteger
    if math.type then
        isInteger = math.type(value) == 'integer'
    else
        ---Lua 5.1/5.2 have no integer subtype, so fall back to the exactly representable range
        isInteger = value % 1 == 0 and value >= -2 ^ 53 and value <= 2 ^ 53
    end
    if isInteger then
        return ("%d"):format(value)
    end

    local text = ("%.14g"):format(value)
    if tonumber(text) ~= value then
        text = ("%.17g"):format(value)
    end
    return text
end

---Strings are pooled into xl/sharedStrings.xml and referenced by a zero based index, which is the
---same layout lib.Workbook reads back
local function _xlsx_internstring(strings, text)
    local index = strings.lookup[text]
    if not index then
        index = #strings.list
        strings.list[index + 1] = text
        strings.lookup[text] = index
    end
    strings.count = strings.count + 1
    return index
end

local function _xlsx_buildcell(cellId, value, strings)
    local valueType = type(value)

    if valueType == 'string' then
        return ('<c r="%s" t="s"><v>%d</v></c>'):format(cellId, _xlsx_internstring(strings, value))
    elseif valueType == 'number' then
        return ('<c r="%s"><v>%s</v></c>'):format(cellId, _xlsx_formatnumber(value))
    elseif valueType == 'boolean' then
        return ('<c r="%s" t="b"><v>%d</v></c>'):format(cellId, value and 1 or 0)
    end

    error(("cannot write a %s value to cell %s"):format(valueType, cellId))
end

---nil values are skipped rather than written as empty cells, which is how .xlsx marks a blank
local function _xlsx_buildrow(rowNum, values, columnCount, strings)
    local cells = {}
    for colNum = 1, columnCount do
        local value = values[colNum]
        if value ~= nil then
            local cellId = ("%s%d"):format(_xlsx_columnname(colNum), rowNum)
            cells[#cells + 1] = _xlsx_buildcell(cellId, value, strings)
        end
    end
    return ('<row r="%d">%s</row>'):format(rowNum, table.concat(cells))
end

local function _xlsx_buildsheetdocument(sheet, columns, strings)
    local columnCount = #columns
    local rows = {}

    if columnCount > 0 then
        ---row 1 is the header, which is what lib.Workbook reads back as the column names
        rows[1] = _xlsx_buildrow(1, columns, columnCount, strings)

        for rowIndex, record in ipairs(sheet.data or {}) do
            local values = {}
            for colNum = 1, columnCount do
                values[colNum] = record[columns[colNum]]
            end
            rows[#rows + 1] = _xlsx_buildrow(rowIndex + 1, values, columnCount, strings)
        end
    end

    local lastCell = ("%s%d"):format(_xlsx_columnname(math.max(columnCount, 1)), math.max(#rows, 1))

    return table.concat {
        xmlHeader,
        ('<worksheet xmlns="%s" xmlns:r="%s">'):format(nsMain, nsRelationships),
        ('<dimension ref="A1:%s"/>'):format(lastCell),
        '<sheetData>',
        table.concat(rows),
        '</sheetData>',
        '</worksheet>',
    }
end

local function _xlsx_buildsharedstringsdocument(strings)
    local entries = {}
    for _, text in ipairs(strings.list) do
        ---xml:space keeps any leading and trailing whitespace the caller deliberately put there
        entries[#entries + 1] = ('<si><t xml:space="preserve">%s</t></si>'):format(_xlsx_escapexml(text))
    end

    return table.concat {
        xmlHeader,
        ('<sst xmlns="%s" count="%d" uniqueCount="%d">'):format(nsMain, strings.count, #strings.list),
        table.concat(entries),
        '</sst>',
    }
end

local function _xlsx_buildworkbookdocument(sheets)
    local entries = {}
    for id, sheet in ipairs(sheets) do
        entries[#entries + 1] = ('<sheet name="%s" sheetId="%d" r:id="rId%d"/>')
            :format(_xlsx_escapexml(sheet.name), id, id)
    end

    return table.concat {
        xmlHeader,
        ('<workbook xmlns="%s" xmlns:r="%s">'):format(nsMain, nsRelationships),
        '<sheets>',
        table.concat(entries),
        '</sheets>',
        '</workbook>',
    }
end

---Worksheets take rId1..rIdN so that sheet%d.xml lines up with the workbook order lib.Workbook
---assumes; styles and shared strings take the two ids after them
local function _xlsx_buildworkbookrelsdocument(sheetCount)
    local entries = {}
    for id = 1, sheetCount do
        entries[#entries + 1] = ('<Relationship Id="rId%d" Type="%s/worksheet" Target="worksheets/sheet%d.xml"/>')
            :format(id, nsRelationships, id)
    end
    entries[#entries + 1] = ('<Relationship Id="rId%d" Type="%s/styles" Target="styles.xml"/>')
        :format(sheetCount + 1, nsRelationships)
    entries[#entries + 1] = ('<Relationship Id="rId%d" Type="%s/sharedStrings" Target="sharedStrings.xml"/>')
        :format(sheetCount + 2, nsRelationships)

    return table.concat {
        xmlHeader,
        ('<Relationships xmlns="%s">'):format(nsPackageRelationships),
        table.concat(entries),
        '</Relationships>',
    }
end

local function _xlsx_buildcontenttypesdocument(sheetCount)
    local entries = {}
    for id = 1, sheetCount do
        entries[#entries + 1] = ('<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="%s.worksheet+xml"/>')
            :format(id, spreadsheetml)
    end

    return table.concat {
        xmlHeader,
        ('<Types xmlns="%s">'):format(nsContentTypes),
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
        ('<Override PartName="/xl/workbook.xml" ContentType="%s.sheet.main+xml"/>'):format(spreadsheetml),
        table.concat(entries),
        ('<Override PartName="/xl/styles.xml" ContentType="%s.styles+xml"/>'):format(spreadsheetml),
        ('<Override PartName="/xl/sharedStrings.xml" ContentType="%s.sharedStrings+xml"/>'):format(spreadsheetml),
        '</Types>',
    }
end

local function _xlsx_buildrootrelsdocument()
    return table.concat {
        xmlHeader,
        ('<Relationships xmlns="%s">'):format(nsPackageRelationships),
        ('<Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/>'):format(nsRelationships),
        '</Relationships>',
    }
end

---The smallest styles.xml Excel will accept; nothing here is referenced by a cell, but the part has
---to be present or the workbook is reported as corrupt
local function _xlsx_buildstylesdocument()
    return table.concat {
        xmlHeader,
        ('<styleSheet xmlns="%s">'):format(nsMain),
        '<fonts count="1"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>',
        '<fills count="2"><fill><patternFill patternType="none"/></fill>',
        '<fill><patternFill patternType="gray125"/></fill></fills>',
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>',
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>',
        '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>',
        '</styleSheet>',
    }
end

---Used when a worksheet carries no column order of its own; alphabetical is arbitrary but stable
local function _xlsx_derivecolumns(data)
    local columns = {}
    local seen = {}
    for _, record in ipairs(data or {}) do
        for key in pairs(record) do
            local column = tostring(key)
            if not seen[column] then
                seen[column] = true
                columns[#columns + 1] = column
            end
        end
    end
    table.sort(columns)
    return columns
end

local function _xlsx_checksheets(sheets)
    if #sheets == 0 then
        error("a workbook needs at least one worksheet")
    end

    local names = {}
    for id, sheet in ipairs(sheets) do
        local name = sheet.name
        if type(name) ~= 'string' or name == '' then
            error(("worksheet %d needs a non-empty name"):format(id))
        elseif #name > sheetNameMaxLength then
            error(("worksheet name %q is longer than %d characters"):format(name, sheetNameMaxLength))
        elseif name:find(sheetNameInvalidPattern) then
            error(("worksheet name %q contains one of the characters : \\ / ? * [ ]"):format(name))
        elseif names[name] then
            error(("worksheet name %q is used by worksheets %d and %d"):format(name, names[name], id))
        end
        names[name] = id
    end
end

--[[
Writes the package out under a temporary name and moves it into place once every part is committed,
so a failure part way through leaves any existing file alone. ZIP.open has no truncate flag, which
is why an existing archive is never opened and rewritten in place here.
--]]
local function _xlsx_writedocuments(filename, documents)
    local tempName = filename .. '.tmp'
    os.remove(tempName)

    local xlsx, err = ZIP.open(tempName, ZIP.OR(ZIP.CREATE, ZIP.EXCL))
    if not xlsx then
        error(("could not create %s: %s"):format(tempName, tostring(err)))
    end

    local ok, addErr = pcall(function()
        for _, document in ipairs(documents) do
            xlsx:add(document[1], 'string', document[2])
        end
        xlsx:close()
    end)
    if not ok then
        os.remove(tempName)
        error(addErr, 0)
    end

    os.remove(filename)
    local renamed, renameErr = os.rename(tempName, filename)
    if not renamed then
        os.remove(tempName)
        error(("could not write %s: %s"):format(filename, tostring(renameErr)))
    end
end

local function _xlsx_savesheets(filename, sheets)
    _xlsx_checksheets(sheets)

    local strings = { list = {}, lookup = {}, count = 0 }
    local sheetDocuments = {}
    for id, sheet in ipairs(sheets) do
        local columns = sheet.columns
        if not columns or #columns == 0 then
            columns = _xlsx_derivecolumns(sheet.data)
        end
        sheetDocuments[id] = _xlsx_buildsheetdocument(sheet, columns, strings)
    end

    ---shared strings are only complete once every worksheet has been built, so that part is added
    ---after the worksheets rather than in package order
    local documents = {
        { '[Content_Types].xml', _xlsx_buildcontenttypesdocument(#sheets) },
        { '_rels/.rels', _xlsx_buildrootrelsdocument() },
        { 'xl/workbook.xml', _xlsx_buildworkbookdocument(sheets) },
        { 'xl/_rels/workbook.xml.rels', _xlsx_buildworkbookrelsdocument(#sheets) },
        { 'xl/styles.xml', _xlsx_buildstylesdocument() },
    }
    for id, document in ipairs(sheetDocuments) do
        documents[#documents + 1] = { ("xl/worksheets/sheet%d.xml"):format(id), document }
    end
    documents[#documents + 1] = { 'xl/sharedStrings.xml', _xlsx_buildsharedstringsdocument(strings) }

    _xlsx_writedocuments(filename, documents)
end


local __workbookMetatableMembers = {
    GetTotalWorksheets = function(self)
        return #self.__sheets
    end,

    GetWorksheet = function(self, key)
        return self.__sheets[key]
    end,

    GetAnsiSheetName = function(self, key)
        return self:GetWorksheet(key).name
    end,

    GetUnicodeSheetName = function(self, key)
        return self:GetWorksheet(key).name
    end,

    GetSheetName = function(self, key)
        return self:GetWorksheet(key).name
    end,

    Sheets = function(self)
        local i = 0
        return function()
            i = i + 1
            return self.__sheets[i]
        end
    end,

    AddWorksheet = function(self, name, columns, data)
        local sheet = { name = name, data = data or {} }
        sheet.columns = columns or _xlsx_derivecolumns(sheet.data)
        self.__sheets[#self.__sheets + 1] = sheet
        return sheet
    end,

    RemoveWorksheet = function(self, key)
        return table.remove(self.__sheets, key)
    end,

    Save = function(self, filename)
        filename = filename or self.filename
        if not filename then
            error("no filename given, and this workbook was not opened from one")
        end
        _xlsx_savesheets(filename, self.__sheets)
        self.filename = filename
        return true
    end
}


local __workbookMetatable = {
    __len = function(self)
        return #self.__sheets
    end,

    __index = function(self, key)
        local value = __workbookMetatableMembers[key]
        if value then return value end
        return self.__sheets[key]
    end
}

---@package
---@class XlsxWorksheet
---@field name string Name shown on the worksheet tab.
---@field columns string[] Column names in sheet order; also written out as the header row.
---@field data table[] One entry per data row, keyed by column name.

---@package
---@class XlsxWorkbook
---@field filename string Path the workbook was opened from.
---@field sharedStrings string[] Raw shared-string table from xl/sharedStrings.xml.
---@field workbookDoc table Parsed xl/workbook.xml document (internal, "@"/"#" shape).
---@field __sheets XlsxWorksheet[] data table keys are column names and values are row values

---Opens an .xlsx file and parses its shared strings, workbook, manifest, and every worksheet.
---@param filename string Path to the .xlsx file to read.
---@return XlsxWorkbook
function lib.Workbook(filename)
    local self = {}
    self.filename = filename

    local sharedStringsXml = _xlsx_readdocument(self, 'xl/sharedStrings.xml')
    self.sharedStrings = {}
    if sharedStringsXml then
        for _, str in ipairs(sharedStringsXml.sst[1]['#'].si) do
            if str['#'].r then
                local concatenatedParts = {}
                for _, rstr in ipairs(str['#'].r) do
                    local t = rstr['#'].t[1]['#']
                    if type(t) == 'string' then
                        concatenatedParts[#concatenatedParts + 1] = rstr['#'].t[1]['#']
                    end
                end
                local concatenatedString = table.concat(concatenatedParts)
                self.sharedStrings[#self.sharedStrings + 1] = concatenatedString
            else
                self.sharedStrings[#self.sharedStrings + 1] = str['#'].t[1]['#']
            end
        end
    end

    self.workbookDoc = _xlsx_readdocument(self, 'xl/workbook.xml')
    local sheets = self.workbookDoc.workbook[1]['#'].sheets
    self.__sheets = {}
    local id = 1
    for _, sheetNode in ipairs(sheets[1]['#'].sheet) do
        local name = sheetNode['@'].name
        local sheet = _xlsx_loadsheet(self, id, name)
        self.__sheets[id] = sheet
        id = id + 1
    end

    setmetatable(self, __workbookMetatable)
    return self
end

---Creates an empty workbook to fill with AddWorksheet and write out with Save.
---@param filename? string Path that Save falls back to when it is called without one.
---@return XlsxWorkbook
function lib.NewWorkbook(filename)
    local self = {}
    self.filename = filename
    self.sharedStrings = {}
    self.__sheets = {}

    setmetatable(self, __workbookMetatable)
    return self
end

---Writes worksheets to an .xlsx file without building a workbook first.
---Each worksheet needs a name and a data array;
---give it a columns array to fix the column order
---otherwise the column names are taken from the data keys and sorted alphabetically.
---@param filename string Path to write to; always writes over
---@param sheets XlsxWorksheet[] Worksheets to write, in tab order.
---@return boolean
function lib.Write(filename, sheets)
    _xlsx_savesheets(filename, sheets)
    return true
end

return lib
