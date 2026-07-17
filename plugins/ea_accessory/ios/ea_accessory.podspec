Pod::Spec.new do |s|
  s.name             = 'ea_accessory'
  s.version          = '0.1.0'
  s.summary          = 'ExternalAccessory (MFi) serial bridge for TESTEV.'
  s.description      = 'Streams bytes to/from an MFi Bluetooth accessory (OBDLink MX+).'
  s.homepage         = 'https://github.com/nicholsbw77/TESTEV'
  s.license          = { :type => 'MIT', :text => 'MIT' }
  s.author           = { 'TESTEV' => 'testev@invalid.example' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
