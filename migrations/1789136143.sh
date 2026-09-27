echo "Map the Asahi mic array to stereo and retry speakersafetyd"

# omarchy-mac's user setup enables the microphone mapper and starts it in a
# live session; this runs it for users set up before.
omarchy-lifecycle-dispatch setup-user
