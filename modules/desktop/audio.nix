# PipeWire (what Ubuntu 26.04 already runs) with PulseAudio compatibility so
# `pactl` in your sway bindings keeps working.
{ ... }:
{
  security.rtkit.enable = true; # realtime priority for the audio daemon
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };
  services.pulseaudio.enable = false;
}
