platform :ios, '15.0'

target 'NosmaiZoomDemo' do
  use_frameworks!

  pod 'NosmaiCameraSDK', '3.0.7'
  # ZoomVideoSDK.framework needs util, zContext and ZoomTask at launch.
  %w[ZoomVideoSDK util zContext ZoomTask].each do |subspec|
    pod "ZoomVideoSDK/#{subspec}", '2.6.15'
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' }
  end
end
