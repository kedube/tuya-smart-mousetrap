// OpenBeken autoexec.bat - Neo Coolcam electric mouse trap, PCB NAS-MA02W6-V1 (BK7231N)
//
// The BK7231N is only a Wi-Fi bridge. The trap's controller powers it up when it has
// something to report, sends datapoints over UART (TuyaMCU low-power protocol v0, 9600 baud),
// and cuts power again when it's done. tmSensor runs the handshake: wait for MQTT -> tell the
// controller "cloud connected" -> receive datapoints -> publish -> ACK.
// The "-1 = not reported yet" channel start values are set in early.bat.

startDriver TuyaMCU
startDriver tmSensor
tuyaMcu_setBaudRate 9600

// Names below are the ones the stock Tuya app shows (checked with the stock firmware, MCU 1.0.8).
// dp101 bool -> ch1: "Mouse killed". The controller sends No (0) every time it's switched on
//                    and Yes (1) when the trap kills. It has no separate "armed" signal: a
//                    fresh No means the trap was just switched on.
// dp102 enum -> ch2: "Battery life", shown in Home Assistant as "Battery" to match its other
//                    battery entities. 0/1/2/3 = 100/75/50/25 %. New cells send 0 on every
//                    battery wake (the Tuya app shows that as 100 %). On the USB-UART adapter
//                    it sends 3 (25 %), so ignore the value there.
// dp103 bool -> ch3: "Low voltage". 1 = replace the batteries. The trap hasn't sent it in any
//                    capture yet, so it's also worked out from the battery reading (below).
linkTuyaMCUOutputToChannel 101 bool 1
// args: [dpId] [type] [channel] [obkFlags] [mult] [inverse] [delta]; value = (raw + delta) * mult,
// so (raw - 4) * -25 turns 0 into 100 % and 3 into 25 %
linkTuyaMCUOutputToChannel 102 enum 2 0 -25 0 -4
linkTuyaMCUOutputToChannel 103 bool 3

// Channel types decide what Home Assistant discovery creates, and the labels become the entity
// names. ReadOnlyEnum makes HA show "No" / "Yes" for Mouse killed instead of Off / On.
setChannelType 1 ReadOnlyEnum
SetChannelEnum 1 0:No 1:Yes
SetChannelLabel 1 "Mouse killed"
setChannelType 2 BatteryLevelPercent
SetChannelLabel 2 Battery
setChannelType 3 OpenClosed_Inv
SetChannelLabel 3 "Low voltage"
// Low voltage from the battery reading, so it isn't left blank: Off at 50 % or more, On at 25 %
// (the lowest step). "if $CH3<0" skips this when the trap already sent its own Low voltage
// value in this wake, so the trap's value always wins.
addChangeHandler Channel2 >= 50 if $CH3<0 then setChannel 3 0
addChangeHandler Channel2 == 25 if $CH3<0 then setChannel 3 1
// ch4: "Armed", worked out here because the trap has no armed datapoint of its own.
// Yes when it reports "Mouse killed: No" (it does that every time it's switched on),
// No when it reports a kill. Change handlers fire when Mouse killed changes to that value;
// early.bat starts both channels at -1 so the first report of each wake always counts.
setChannelType 4 ReadOnlyEnum
SetChannelEnum 4 0:No 1:Yes
SetChannelLabel 4 "Armed"
addChangeHandler Channel1 == 0 setChannel 4 1
addChangeHandler Channel1 == 1 setChannel 4 0

// Retain every publish, so Home Assistant keeps the last state while the trap is powered off
SetFlag 7 1
// Let TuyaMCU-linked channels be included in publishes
SetFlag 19 1
// Publish the chip's own state (RSSI, uptime, temperature, SSID, IP, build) on each wake.
// Home Assistant discovery only creates those sensors while this (or flag 2) is on. The
// broadcast re-sends the channels last, about 20 s in, which is usually after the trap has
// cut power; if it gets that far, a value the trap never sent goes out as -1 (shown as unknown).
SetFlag 10 1
// No repeating broadcast every minute
SetFlag 2 0
// Leave the availability topic out of discovery, so entities keep their last value instead of
// going "unavailable" whenever the trap sleeps. Re-run HA discovery after changing this.
SetFlag 35 1
// Fast connect: join Wi-Fi and MQTT immediately at boot. Takes effect from the next boot once
// saved, so do the first boot after uploading on adapter power. Use with a static IP.
SetFlag 37 1

// Firmware-update questions. Each wake the controller asks "Wi-Fi firmware update?" (0x0A)
// and, once that's answered, "controller firmware update?" (0x0C). "No update" (0x01) lets it
// power off. Stock firmware answers only after asking Tuya's servers. With these delayed
// answers (and controller firmware 1.0.8) battery life arrives on every wake; with instant
// answers on 1.0.7 it never did.
// Keep this at the end of the file: waitFor pauses the script until the question arrives.
waitFor TuyaMCUParsed 10
delay_s 3
tuyaMcu_sendCmd 10 01
waitFor TuyaMCUParsed 12
delay_s 2
tuyaMcu_sendCmd 12 01
