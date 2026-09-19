test:
	nvim --headless -c "luafile tests/nanodiff_spec.lua" -c "qa!"
