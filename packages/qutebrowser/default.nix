{ pkgs }:

# qutebrowser with the Qt 6.5 hinting fix applied.
#
# Fixes "Unknown error while getting elements" when using follow/hint on pages
# with subframes (Qt 6.5 regression). The upstream patch (qutebrowser issue
# #7662, The-Compiler) moves the injected early scripts from the per-page
# QWebEngineScript collection to the per-profile collection, which the web
# engine actually uses across pages.
#
# See: qutebrowser-profile-scripts.patch
#
# Note: `pkgs.qutebrowser.override { enableWideVine = true; }.overrideAttrs`
# does not work here — qutebrowser is built with buildPythonApplication, and
# chaining plain `override`/`overrideAttrs` on such packages breaks in this
# nixpkgs (makeOverridablePythonPackage quirk). So instead of `.override`, the
# widevine flag (which is all `enableWideVine` does) is replicated explicitly
# in `preFixup`, using the same path nixpkgs uses.
pkgs.qutebrowser.overrideAttrs (old: {
  pname = "qutebrowser-widevine-hintfix";
  patches = (old.patches or [ ]) ++ [
    ./qutebrowser-profile-scripts.patch
  ];
  preFixup = old.preFixup + ''
    makeWrapperArgs+=(
      --add-flags "--qt-flag widevine-path=${pkgs.widevine-cdm}/share/google/chrome/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so"
    )
  '';
})
