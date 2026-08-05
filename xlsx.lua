--[[
* lua-xlsx
*
* Based on the original implementation by Josh Jensen.
* Modified to be compatible with Lua 5.3 and lib-zip by Simon Spivey.
*
--]]

---The module lua-xlsx allows read access to .xlsx files.
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
            minor = 1,
            revision = 1,
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
                for colNum, value in pairs(rowValues) do
                    headers[colNum] = (value ~= nil and value ~= '') and tostring(value) or ('Column' .. colNum)
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

    return { name = name, data = data }
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
---@class XlsxWorkbook
---@field filename string Path the workbook was opened from.
---@field sharedStrings string[] Raw shared-string table from xl/sharedStrings.xml.
---@field workbookDoc table Parsed xl/workbook.xml document (internal, "@"/"#" shape).
---@field __sheets {name:string, data:table[]}[] data table keys are column names and values are row values

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
                local concatenatedString = {}
                for _, rstr in ipairs(str['#'].r) do
                    local t = rstr['#'].t[1]['#']
                    if type(t) == 'string' then
                        concatenatedString[#concatenatedString + 1] = rstr['#'].t[1]['#']
                    end
                end
                concatenatedString = table.concat(concatenatedString)
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

return lib