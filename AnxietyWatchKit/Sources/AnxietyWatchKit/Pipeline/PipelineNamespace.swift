import Foundation

public enum Pipeline {}/// Re-export CNSMonitoringCoordinator under a disambiguated name for
/// app targets that already define their own CNSMonitoringCoordinator.
/// Use `PipelineCoordinator` when the app-level class shadows the framework
/// actor of the same name.
public typealias PipelineCoordinator = CNSMonitoringCoordinator
