local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, "NanodiffFilePanelTitle", {
    link = "Title",
  })
  vim.api.nvim_set_hl(0, "NanodiffFilePanelCounter", {
    link = "Number",
  })
  vim.api.nvim_set_hl(0, "NanodiffFilePanelFileName", {
    link = "Normal",
  })
  vim.api.nvim_set_hl(0, "NanodiffFilePanelSelected", {
    link = "Visual",
  })
  vim.api.nvim_set_hl(0, "NanodiffFolderName", {
    link = "Directory",
  })
  vim.api.nvim_set_hl(0, "NanodiffSecondary", {
    link = "Normal", -- ?
  })
  vim.api.nvim_set_hl(0, "NanodiffRef", {
    link = "Constant",
  })
  vim.api.nvim_set_hl(0, "NanodiffCommitLine", {
    link = "Statement",
  })
  vim.api.nvim_set_hl(0, "NanodiffItemKey", {
    link = "String",
  })
  vim.api.nvim_set_hl(0, "NanodiffHash", {
    link = "Function",
  })
  vim.api.nvim_set_hl(0, "NanodiffDim", {
    link = "Comment",
  })
  vim.api.nvim_set_hl(0, "NanodiffAdd", {
    link = "DiffAdd",
  })
  vim.api.nvim_set_hl(0, "NanodiffDelete", {
    link = "DiffDelete",
  })
  vim.api.nvim_set_hl(0, "NanodiffFolderIcon", {
    link = "PreProc",
  })
  vim.api.nvim_set_hl(0, "NanodiffConflicts", {
    link = "DiagnosticSignWarn",
  })
  vim.api.nvim_set_hl(0, "NanodiffNonText", {
    link = "NonText",
  })
end

return M
