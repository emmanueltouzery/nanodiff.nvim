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

function M.async_progress(title, task_fn)
  local msg_id = vim.api.nvim_echo({{'Loading...'}}, true, {
    kind='progress', status='running', title=title, source='nanodiff', percent = nil
  })
  async.run(task_fn)
    :raise_on_error()
    :on_complete(function(err, res)
      vim.schedule(function()
        local status = 'failed'
        if err == nil then
          status = 'success'
        end
        vim.api.nvim_echo({{'Done'}}, true, {
          id = msg_id, kind='progress', status=status, source='nanodiff', title=title
        })
      end)
    end)
end

return M
