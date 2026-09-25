# EOSG binaries (not in the repo)

This folder holds the compiled Epic Online Services plugin (EOSG 2.3.1) and
Epic's SDK library. They are **not committed** — the Epic SDK is Epic's, and
the files are large. Every machine that opens the project in the editor or
builds the Windows/Linux game needs them once.

## Install (5 minutes)

1. Open the project in **Godot 4.5**. Until this folder is filled you will see
   red "GDExtension … not found" / "IEOS not declared" errors — expected.
2. **AssetLib** tab (top centre) → search **EOSG** → *Epic Online Services
   Godot (EOSG)* by 3ddelano, **version 2.3.1 or newer** → Download.
3. In the install dialog keep **only** `addons/epic-online-services-godot/bin/`
   ticked (the scripts are already in the repo) → Install.
4. **Project → Reload Current Project.** The errors are gone.

Alternative: download the EOSG 2.3.1 release zip from
<https://github.com/3ddelano/epic-online-services-godot/releases> and copy its
`addons/epic-online-services-godot/bin/` folder here.

You need at least:

```
bin/windows/libeosg.windows.template_release.x86_64.dll
bin/windows/libeosg.windows.template_debug.dev.x86_64.dll
bin/windows/EOSSDK-Win64-Shipping.dll
bin/windows/x64/xaudio2_9redist.dll
bin/linux/...   (only to build/test on Linux)
```

The **browser** build does not use these at all (`tools/build/export_web.sh`
removes the plugin for the web export).
