#!/usr/bin/env ruby
# Adds the NovaAIKit Swift package to an Xcode project that has no project.yml (pbxproj apps).
#
#   gem install xcodeproj   # once (1.27+)
#   ruby add-novaaikit.rb path/to/App.xcodeproj AppTarget [AppTests] [--mlx] [--version 1.0.0]
#
# Every named target gets the NovaAIKit product (--mlx also links NovaAIKitMLX into the FIRST target only).
# Idempotent: re-running changes nothing. Package URL is the public https one (no credentials).
require 'xcodeproj'

URL = 'https://github.com/kochj23/NovaAIKit.git'
args = ARGV.dup
mlx = args.delete('--mlx')
version = '1.0.0'
if (i = args.index('--version'))
  version = args[i + 1]
  args.slice!(i, 2)
end
abort "usage: add-novaaikit.rb App.xcodeproj Target [MoreTargets…] [--mlx] [--version X.Y.Z]" if args.size < 2
project_path, *target_names = args

proj = Xcodeproj::Project.open(project_path)
pkg = proj.root_object.package_references.find { |r| r.respond_to?(:repositoryURL) && r.repositoryURL == URL }
unless pkg
  pkg = proj.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  pkg.repositoryURL = URL
  proj.root_object.package_references << pkg
end
pkg.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => version }

def link(proj, target, pkg, product)
  return if target.package_product_dependencies.any? { |d| d.product_name == product }
  dep = proj.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = product
  target.package_product_dependencies << dep
  bf = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  target.frameworks_build_phase.files << bf
end

target_names.each_with_index do |name, i|
  t = proj.targets.find { |x| x.name == name } or abort "no target #{name} (have: #{proj.targets.map(&:name).join(', ')})"
  link(proj, t, pkg, 'NovaAIKit')
  link(proj, t, pkg, 'NovaAIKitMLX') if mlx && i.zero?
end
proj.save
puts "NovaAIKit #{version}+ linked into: #{target_names.join(', ')}#{mlx ? ' (+NovaAIKitMLX)' : ''}"
