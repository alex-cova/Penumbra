/*******************************************************************************
 * Copyright (c) 2009, 2019 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

package class BasicProgressMonitor: IElkProgressMonitor {

    package static let UNKNOWN_WORK: Float = -1
    package static let ROOT_DEBUG_FOLDER_NAME = "logs"
    package static let INFINITE_HIERARCHY_LEVELS = -1

    // MARK: - Stored state

    private var _parentMonitor: (any IElkProgressMonitor)?
    private var _children: [IElkProgressMonitor] = []
    private var maxLevels: Int = BasicProgressMonitor.INFINITE_HIERARCHY_LEVELS

    private var _taskName: String = ""
    private var closed = false
    private var _totalWork: Float = 0.0
    private var completedWork: Float = 0.0
    private var currentChildWork: Float = -1.0

    private var recordLogs = false
    private var persistLogs = false
    private var _logMessages: [String] = []
    private var _logGraphs: [LoggedGraph] = []

    private var _debugFolder: URL?
    private var logFile: URL?

    private var recordExecutionTime = false
    private var startTime: TimeInterval?
    private var _totalTime: Double = 0.0

    // MARK: - Protocol computed properties

    package var taskName: String { return _taskName }
    package var subMonitors: [IElkProgressMonitor] { return _children }
    package var parentMonitor: (any IElkProgressMonitor)? { return _parentMonitor }
    package var logs: [String] { return _logMessages }
    package var loggedGraphs: [LoggedGraph] { return _logGraphs }
    package var debugFolder: URL? { return _debugFolder }
    package var executionTime: Double { return _totalTime }

    // MARK: - Init

    package init() {}

    // MARK: - Configuration

    @discardableResult
    package func withMaxHierarchyLevels(_ levels: Int) -> BasicProgressMonitor {
        if levels < 0 {
            self.maxLevels = BasicProgressMonitor.INFINITE_HIERARCHY_LEVELS
        } else {
            self.maxLevels = levels
        }
        return self
    }

    @discardableResult
    package func withLogging(_ enabled: Bool) -> BasicProgressMonitor {
        recordLogs = enabled
        if !recordLogs {
            _logMessages = []
            _logGraphs = []
        }
        return self
    }

    @discardableResult
    package func withLogPersistence(_ enabled: Bool) -> BasicProgressMonitor {
        persistLogs = enabled
        return self
    }

    @discardableResult
    package func withExecutionTimeMeasurement(_ enabled: Bool) -> BasicProgressMonitor {
        recordExecutionTime = enabled
        return self
    }

    // MARK: - Work

    @discardableResult
    package func begin(_ name: String, _ totalWork: Float) -> Bool {
        guard !closed else {
            assertionFailure("The task is already done.")
            return false
        }
        guard _taskName.isEmpty else {
            return false
        }

        self._taskName = name
        self._totalWork = totalWork

        doBegin(name: name, newTotalWork: totalWork, topInstance: _parentMonitor == nil, maxHierarchyLevels: maxLevels)

        if recordExecutionTime {
            startTime = Date().timeIntervalSince1970
        }

        return true
    }

    package func doBegin(name: String, newTotalWork: Float, topInstance: Bool, maxHierarchyLevels: Int) {
        // Override in subclasses
    }

    package func worked(_ work: Float) {
        guard work > 0, !closed else { return }
        internalWorked(work: work)
    }

    package func internalWorked(work: Float) {
        guard _totalWork > 0, completedWork < _totalWork else { return }

        completedWork += work
        doWorked(completedWork: completedWork, totalWork: _totalWork, topInstance: _parentMonitor == nil)

        if let parent = _parentMonitor as? BasicProgressMonitor, parent.currentChildWork > 0, maxLevels != 0 {
            parent.internalWorked(work: work / _totalWork * parent.currentChildWork)
        }
    }

    package func doWorked(completedWork: Float, totalWork: Float, topInstance: Bool) {
        // Override in subclasses
    }

    package func done() {
        guard !_taskName.isEmpty else {
            assertionFailure("The task has not begun yet.")
            return
        }

        guard !closed else { return }

        if recordExecutionTime, let start = startTime {
            let end = Date().timeIntervalSince1970
            _totalTime = end - start
        }

        if completedWork < _totalWork {
            internalWorked(work: _totalWork - completedWork)
        }

        doDone(topInstance: _parentMonitor == nil, maxHierarchyLevels: maxLevels)
        closed = true
    }

    package func doDone(topInstance: Bool, maxHierarchyLevels: Int) {
        // Override in subclasses
    }

    package func isRunning() -> Bool {
        return !_taskName.isEmpty && !closed
    }

    package func isCanceled() -> Bool {
        return false
    }

    // MARK: - Sub-Tasks

    package func subTask(_ work: Float) -> (any IElkProgressMonitor)? {
        guard !closed else { return nil }

        let subMonitor = doSubTask(work: work, maxHierarchyLevels: maxLevels)
        _children.append(subMonitor)
        subMonitor._parentMonitor = self
        currentChildWork = work
        return subMonitor
    }

    package func doSubTask(work: Float, maxHierarchyLevels: Int) -> BasicProgressMonitor {
        let newMaxHierarchyLevels = maxHierarchyLevels > 0 ? maxHierarchyLevels - 1 : maxHierarchyLevels
        return BasicProgressMonitor()
            .withMaxHierarchyLevels(newMaxHierarchyLevels)
            .withLogging(recordLogs)
            .withLogPersistence(persistLogs)
            .withExecutionTimeMeasurement(recordExecutionTime)
    }

    // MARK: - Debugging

    package func isLoggingEnabled() -> Bool {
        return recordLogs
    }

    package func isLogPersistenceEnabled() -> Bool {
        return persistLogs
    }

    package func log(_ object: Any) {
        guard recordLogs else { return }
        let message = String(describing: object)
        _logMessages.append(message)
    }

    package func logGraph(_ graph: ElkNode, _ tag: String) {
        guard recordLogs else { return }
        logGraph(graph as Any, tag, .elk)
    }

    package func logGraph(_ object: Any, _ tag: String, _ graphType: LoggedGraph.GraphType) {
        guard recordLogs else { return }
        if let loggedGraph = try? LoggedGraph(graph: object, tag: tag, graphType: graphType) {
            _logGraphs.append(loggedGraph)
        }
    }

    package func isExecutionTimeMeasured() -> Bool {
        return recordExecutionTime
    }
}

// MARK: - TimeoutProgressMonitor

package class TimeoutProgressMonitor: BasicProgressMonitor {
    private let deadline: CFAbsoluteTime

    package init(timeout: TimeInterval) {
        self.deadline = CFAbsoluteTimeGetCurrent() + timeout
        super.init()
    }

    override package func isCanceled() -> Bool {
        CFAbsoluteTimeGetCurrent() > deadline
    }
}
