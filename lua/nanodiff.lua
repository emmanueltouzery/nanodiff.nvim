local async = vim.async
local options = require('core.options')
local git_adapter = require('git.git')

local M = {
  lib = {
    filetree = require('core.filetree'),
    tabdata = require('core.tabdata'),
  },
}

local function with_vsc(opts, cb)
  async.run(function()
    local tasks = vim.tbl_map(function(a)
      return async.run(function()
        return a, a.get_repo_root()
      end):detach()
    end, opts.vcs_adapters or {git_adapter})

    local best_adapter = nil
    local shortest_path = nil
    for task in async.iter(tasks) do
      local ok, a, path = async.pawait(task)
      if ok then
        if shortest_path == nil or #path < #shortest_path then
          best_adapter = a
          shortest_path = path
        end
      end
    end

    if best_adapter then
      cb(best_adapter, opts)
    else
      vim.notify("No source control repository found!", vim.log.levels.WARN, {source="nanodiff"})
    end
  end):raise_on_error()
end

function M.status(opts)
  opts = options.apply_option_defaults(opts, options.get_status_options())
  with_vsc(opts, function(adapter, opts)
    adapter.status(opts)
  end)
end

function M.revspec(revspec, opts)
  opts = options.apply_option_defaults(opts, options.get_revspec_options())
  with_vsc(opts, function(adapter, opts)
    adapter.revspec(revspec, opts)
  end)
end

function M.log(opts)
  opts = options.apply_option_defaults(opts, options.get_log_options())
  with_vsc(opts, function(adapter, opts)
    adapter.log(opts)
  end)
end

function M.stashes(opts)
  opts = options.apply_option_defaults(opts, options.get_log_options())
  with_vsc(opts, function(adapter, opts)
    adapter.stashes(opts)
  end)
end

return M
