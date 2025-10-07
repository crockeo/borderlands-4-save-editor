build:
	zig build

run:
	zig build run

test:
	zig build test --summary all

watch +args:
	watchexec -w . -e zig -- just {{args}}
