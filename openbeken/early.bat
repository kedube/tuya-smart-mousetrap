// Runs at the very start of boot, before drivers and before the MQTT client exists.
// Set the "not reported yet" sentinels here so the first real report of any value -
// including 0 - counts as a change and gets published. Nothing can leak to MQTT from
// here; setting these in autoexec.bat published retained -1s once fast-connect made
// MQTT come up early (seen in testing).
setChannel 1 -1
setChannel 2 -1
setChannel 3 -1
// Armed (set from Mouse killed in autoexec.bat)
setChannel 4 -1
