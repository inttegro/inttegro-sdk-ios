Pod::Spec.new do |spec|
  spec.name = 'Inttegro'
  spec.version = '0.3.0'
  spec.summary = 'Native Inttegro checkout and payment sheet for iOS.'
  spec.homepage = 'https://inttegro.com'
  spec.license = { type: 'MIT' }
  spec.author = { 'Inttegro Eng' => 'engineering@inttegro.com' }
  spec.source = {
    git: 'https://github.com/inttegro/inttegro-sdk-ios.git',
    tag: "v#{spec.version}",
  }
  spec.source_files = 'Sources/**/*.swift'
  spec.resource_bundles = {
    'Inttegro' => ['Sources/Inttegro/Resources/**/*.xcassets'],
  }
  spec.ios.deployment_target = '16.0'
  spec.swift_version = '6.0'
  spec.requires_arc = true
  spec.frameworks = 'CryptoKit', 'Foundation', 'SafariServices', 'SwiftUI', 'UIKit'
end
