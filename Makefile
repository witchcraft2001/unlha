.PHONY: all exe img run clean

all: exe

exe:
	tools/build.sh

img: exe
	tools/image.sh

# Запуск в MAME с образа дискеты. Машина/настройки уточняются под локальную
# конфигурацию MAME для Sprinter; цель оставлена как точка входа.
run: img
	@echo "Run in MAME, e.g.:"
	@echo "  mame sprinter -flop1 build/unlha.img"

clean:
	rm -rf build
