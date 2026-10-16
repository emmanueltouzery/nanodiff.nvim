local M = {}

function M.get_common_options()
  return {
    shortcuts = {
      activate = "<CR>",
      scroll_backward = "<C-b>",
      scroll_forward = "<C-f>",
      prev_file = "<S-TAB>",
      next_file = "<TAB>",
    }
  }
end

function M.get_log_options()
  return vim.tbl_deep_extend("force", M.get_common_options(), {
    shortcuts = {
      filters = "g!",
      yank_commit = "y",
    },
    relative_date_cutoff_seconds = 3 * 24 * 60 * 60,
    panel_height = 15,
  })
end

function M.get_diff_options()
  return vim.tbl_deep_extend("force", M.get_common_options(), {
    panel_width = 40,
  })
end

function M.get_status_options()
  return vim.tbl_deep_extend("force", M.get_diff_options(), {
    shortcuts = {
      stage_unstage = "s",
      drop_changes = "X",
    },
  })
end

function M.apply_option_defaults(opts, defaults)
  return vim.tbl_deep_extend("keep", opts or {}, defaults)
end

return M
