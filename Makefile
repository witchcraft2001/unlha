.PHONY: all exe img run dist clean

all: exe

exe:
	tools/build.sh

img: exe
	tools/image.sh

# Дистрибутив dist/unlha_<ver>.zip (unlha.exe + unlhaen.txt англ. + unlha.txt рус./CP866)
dist: exe
	tools/dist.sh

# Запуск в MAME с образа дискеты. Машина/настройки уточняются под локальную
# конфигурацию MAME для Sprinter; цель оставлена как точка входа.
run: img
	@echo "Run in MAME, e.g.:"
	@echo "  mame sprinter -flop1 build/unlha.img"

clean:
	rm -rf build dist/stage dist/*.zip
