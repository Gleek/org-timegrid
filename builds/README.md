# Android font build

Android Emacs cannot render SVG text, so `org-timegrid-android-font.el`
contains pre-generated glyph paths. Users do not need Python or FontTools.

To regenerate it, create an isolated environment, install the pinned build
dependency, and pass a TTF or OTF to the generator:

```sh
python3 -m venv builds/.venv
builds/.venv/bin/pip install -r builds/requirements.txt
builds/.venv/bin/python builds/generate-android-font.py \
  /path/to/font.ttf org-timegrid-android-font.el
```

Variable fonts are instantiated at weights 400 and 500 by default. For a static
family, provide its bold face separately:

```sh
builds/.venv/bin/python builds/generate-android-font.py \
  Regular.otf org-timegrid-android-font.el --bold-font Medium.otf
```

Use `--regular-weight`, `--bold-weight`, or `--characters` to override the
defaults. The generator reads the family, version, and copyright from the font
and only instantiates variation axes that it provides. Commit the generated
Elisp with any generator or source-font change.
