--- Deliberately minimal: the core of the plugin is plain Lua, so the tests run
--- under `lua`, `luajit` or `nvim -l` without any external framework.

local M = {
  passed = 0,
  failed = 0,
  failures = {},
  group = nil,
}

---@param name string
---@param fn fun()
function M.describe(name, fn)
  local prev = M.group
  M.group = prev and (prev .. " / " .. name) or name
  fn()
  M.group = prev
end

---@param name string
---@param fn fun()
function M.it(name, fn)
  local label = (M.group and (M.group .. " / ") or "") .. name
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = label .. "\n    " .. tostring(err)
    io.write("FAIL ", label, "\n  ", tostring(err), "\n")
  end
end

---@param value any
---@return string
local function show(value)
  if type(value) == "table" then
    local parts = {}
    for k, v in pairs(value) do
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(value)
end

function M.eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", show(expected), show(actual)), 2)
  end
end

function M.ok(value, msg)
  if not value then
    error(msg or "expected a truthy value", 2)
  end
end

function M.is_nil(value, msg)
  if value ~= nil then
    error((msg or "expected nil") .. ", got " .. show(value), 2)
  end
end

---@param haystack string
---@param needle string
function M.contains(haystack, needle)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error(string.format("expected %q to contain %q", tostring(haystack), needle), 2)
  end
end

---@param list string[]
---@param needle string
function M.list_contains(list, needle)
  for _, v in ipairs(list) do
    if v == needle then
      return
    end
  end
  error(string.format("expected list to contain %q (got %s)", needle, table.concat(list, " | ")), 2)
end

---@return integer exit code
function M.summary()
  io.write(string.format("\n%d passed, %d failed\n", M.passed, M.failed))
  if M.failed > 0 then
    io.write("\nFailures:\n")
    for _, f in ipairs(M.failures) do
      io.write("  - ", f, "\n")
    end
    return 1
  end
  return 0
end

return M
