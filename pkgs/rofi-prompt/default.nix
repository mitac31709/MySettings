# Unified Rofi password and confirmation prompts (Askpass, Pinentry, Polkit).
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  rofi,
  pinentry-curses,
  systemd,
  coreutils,
}:

stdenvNoCC.mkDerivation {
  pname = "rofi-prompt";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python3 ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    python3 -B -m unittest discover -s . -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 rofi_prompt.py "$out/libexec/rofi_prompt.py"
    install -Dm644 password.rasi "$out/share/rofi-prompt/password.rasi"
    substituteInPlace "$out/libexec/rofi_prompt.py" \
      --replace-fail "#!/usr/bin/env python3" "#!${lib.getExe python3}"

    for mode in askpass pinentry polkit; do
      makeWrapper "$out/libexec/rofi_prompt.py" "$out/bin/rofi-$mode" \
        --set ROFI_PROMPT_MODE "$mode" \
        --set ROFI_PROMPT_THEME "$out/share/rofi-prompt/password.rasi" \
        --set ROFI_BIN "${lib.getExe rofi}" \
        --set PINENTRY_CURSES_BIN "${lib.getExe pinentry-curses}" \
        --prefix PATH : "${
          lib.makeBinPath [
            rofi
            pinentry-curses
            systemd
            coreutils
          ]
        }"
    done

    runHook postInstall
  '';

  meta = {
    description = "Unified Rofi prompt for SSH/sudo askpass, Assuan pinentry, and cmd-polkit";
    platforms = lib.platforms.linux;
    mainProgram = "rofi-pinentry";
  };
}
