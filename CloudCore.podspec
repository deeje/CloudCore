Pod::Spec.new do |s|
  s.name             = "CloudCore"
  s.summary          = "Framework that enables synchronization between CloudKit and Core Data."
  s.version          = "6.0.0"
  s.homepage         = "https://github.com/deeje/CloudCore"
  s.license          = 'MIT'
  s.author           = { "deeje" => "deeje@mac.com", "Vasily Ulianov" => "vasily@me.com" }
  s.source           = {
    :git => "https://github.com/deeje/CloudCore.git",
    :tag => s.version.to_s
  }

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.tvos.deployment_target = '15.0'
  s.watchos.deployment_target = '8.0'

  s.source_files = 'CloudCore/**/*.swift'

  s.ios.frameworks = 'Foundation', 'CloudKit', 'CoreData'
  s.osx.frameworks = 'Foundation', 'CloudKit', 'CoreData'
  s.tvos.frameworks = 'Foundation', 'CloudKit', 'CoreData'
  s.watchos.frameworks = 'Foundation', 'CloudKit', 'CoreData'

  s.swift_versions = [5.4]
end
