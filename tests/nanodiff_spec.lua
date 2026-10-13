vim.opt.rtp:append(".")
local filetree = require("core.filetree")

print("Running tests...")

local function assert_equals(expected, actual)
  if vim.inspect(expected) ~= vim.inspect(actual) then
    assert(false, "\nactual: " .. vim.inspect(actual) .. " ~= expected: " .. vim.inspect(expected))
  end
end

-- build_tree should keep extra fields besides path and just copy them to the leaves
-- test with fake f, g, h fields
assert_equals(
  {
    {
      path = "a",
      is_dir = true,
      subs = {
        { path = "b", f = 12},
        { path = "c", g = 13},
      }
    }, {
      path = "d", h = 14
    },
  } , filetree._private.build_tree({{path = "a/b", f = 12}, {path = "a/c", g = 13}, {path = "d", h = 14}})
)

-- auto-merge empty subfolders
-- folders are sorted before files
assert_equals(
  {
    {
      path = "x/b",
      is_dir = true,
      subs = {
        { path = "c", f = 12},
      }
    }, {
      path = "d", h = 14
    },
  } , filetree._private.build_tree({{path = "x/b/c", f = 12}, {path = "d", h = 14}})
)


print("✅ All tests passed!")
