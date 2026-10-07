.PHONY: build test run app clean lint measure

build:
	swift build

test:
	swift test

# Assembles dist/Cornice.app and launches it.
run: app
	open dist/Cornice.app

app:
	./Scripts/bundle.sh release

# Debug bundle: faster to build, keeps assertions on.
app-debug:
	./Scripts/bundle.sh debug

clean:
	swift package clean
	rm -rf dist

# Measure CPU and memory while the panel is closed.
measure:
	./Scripts/measure.sh
