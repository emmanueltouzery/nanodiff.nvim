local M = {}

local async = vim.async
local uv = vim.uv

M.async_sys = async.wrap(3, vim.system)
M.async_fs_unlink = async.wrap(2, uv.fs_unlink)
M.async_fs_lstat = async.wrap(2, uv.fs_lstat)

function M.run_cmd(cmd, opts)
  local res = M.async_sys(cmd, opts)
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

local fs_open = async.wrap(4, uv.fs_open)
local fs_read = async.wrap(4, uv.fs_read)
local fs_close = async.wrap(2, uv.fs_close)

function M.count_file_lines(path)
  return async.run(function()
    local err, lstat = M.async_fs_lstat(path)
    assert(not err, err)
    if lstat.type ~= "file" then
      -- could be a symlink, a folder...
      return nil
    end

    local err, fd = fs_open(path, "r", 0)
    assert(not err, err)

    local ok, result = pcall(function()
      local lines, offset, last_byte = 0, 0, nil

      while true do
        local err, chunk = fs_read(fd, 64 * 1024, offset)
        assert(not err, err)

        if #chunk == 0 then
          break
        end

        local _, n = chunk:gsub("\n", "")
        lines = lines + n
        offset = offset + #chunk
        last_byte = chunk:sub(-1)
      end

      if last_byte and last_byte ~= "\n" then
        lines = lines + 1
      end

      return lines
    end)

    local close_err = fs_close(fd)
    assert(not close_err, close_err)

    if not ok then
      error(result, 0)
    end

    return result
  end)
end

return M
