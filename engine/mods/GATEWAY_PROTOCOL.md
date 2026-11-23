# Tesla Gateway UDP API Protocol

## Connection
- Host: 192.168.90.102 (gateway IP, or localhost for emulator)
- Port: 3500 (UDP)

## Commands (binary, shown as hex)

### Read Config Value
Request:  `0b 00 <config_id_byte>`
Response: current value bytes

### Write Config Value  
Request:  `0c 00 <config_id_byte> <value_byte(s)>`
Response: echoes command back on SUCCESS, `ff` on SECURED/FAIL

### Write VIN
Request:  `0c 00 00 <17-byte VIN as ASCII hex>`
Response: echoes back on success

### Promote (escalate privileges)
Request:  `14 de ad be ef`

### Unlock Switch
Request:  `18 ba bb a0 ad`

## Config IDs (decimal → hex)
- 0: VIN (string, 17 chars)
- 6: country (string: US, DE, etc.)
- 7: exteriorColor
- 8: drivetrainType
- 9: airSuspension
- 14: packEnergy
- 15: devSecurityLevel
- 28: headlamps (0=base, 1=premium, 2=global)
- 29: autopilot
- 30: superchargingAccess (0=not_allowed, 1=allowed, 2=pay_as_you_go)
- 41: wheelType
- 44: pedestrianWarning / boombox
- 48: performancePackage (0=base, 1=performance, 3=base_plus)
- 58: rearFogLamps
- 59: dasHw (3=PARKER_PASCAL_2_5, 4=TESLA_AP3)
- 64: trackModePackage (0=none, 1=performance, 2=enabled_ui_sos)
- 66: mapRegion (0=US, 1=EU, 3=CN, 4=AU, 5=JP)
- 67: spoiler_rear
- 70: plcSupport (0=none, 1=onboard, 2=native)
- 132: tiltScreen
- 133: frontUsbHubType
- 150: caliperColorType
