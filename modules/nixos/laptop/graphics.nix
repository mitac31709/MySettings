# Shared Intel laptop firmware + VA-API (8th+ gen iGPU / SOF).
{ pkgs, ... }:

{
  # SOF DSP firmware (Tiger Lake Chromebook + 10th+ gen Intel VAIO).
  # Keep redistributable firmware from modules/nixos/common.nix and add SOF here.
  hardware.firmware = [ pkgs.sof-firmware ];

  # Ice Lake eDP (VAIO): i915_flip stuck in drm_atomic_helper_wait_for_flip_done
  # (GPU HANG ecode 11:0:00000000) for many minutes → procs_blocked/iowait tax.
  # PSR=0 alone was not enough after reboot; also disable display power DC states.
  boot.kernelParams = [
    "i915.enable_psr=0"
    "i915.enable_dc=0"
  ];

  # Intel iGPU (8th+ gen / Iris Xe / Core Ultra): VA-API for Parsec's
  # FFMPEG hardware encode/decode. Without intel-media-driver there is no
  # iHD_drv_video.so under /run/opengl-driver and Parsec falls back to software.
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [ intel-media-driver ];
  };

  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
}
