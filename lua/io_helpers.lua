local async = vim.async
local async_sys = async.wrap(3, vim.system)

local M = {}

function M.run_cmd(cmd, opts)
  local res = async_sys(cmd, opts)
  if res.code ~= 0 then
    error(table.concat(cmd, " ") .. " error: " .. res.stderr)
  end
  return res.stdout
end

return M
