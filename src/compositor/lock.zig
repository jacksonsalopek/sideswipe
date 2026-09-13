//! Session lock state machine (ext_session_lock_v1).

const testing = @import("core").testing;

pub const Phase = enum {
    idle,
    locking,
    locked,
    finished,
};

pub const Machine = struct {
    phase: Phase = .idle,
    /// Owner object is gone; session stays locked until a new locker confirms.
    abandoned: bool = false,

    pub fn begin(self: *Machine) error{AlreadyLocked}!void {
        if (self.phase == .locking) return error.AlreadyLocked;
        if (self.phase == .locked and !self.abandoned) return error.AlreadyLocked;
        self.phase = .locking;
    }

    pub fn confirm(self: *Machine) void {
        if (self.phase != .locking) return;
        self.phase = .locked;
        self.abandoned = false;
    }

    pub fn unlock(self: *Machine) error{InvalidUnlock}!void {
        if (self.phase != .locked) return error.InvalidUnlock;
        self.phase = .idle;
        self.abandoned = false;
    }

    pub fn destroy(self: *Machine) error{InvalidDestroy}!void {
        if (self.phase == .locked and !self.abandoned) return error.InvalidDestroy;
        self.phase = .idle;
        self.abandoned = false;
    }

    pub fn clientDied(self: *Machine) void {
        if (self.phase == .finished) {
            self.phase = .idle;
            return;
        }
        if (self.phase == .locking) {
            self.phase = if (self.abandoned) .locked else .idle;
            return;
        }
        if (self.phase == .locked) self.abandoned = true;
    }

    pub fn dropsInput(self: Machine) bool {
        return self.phase == .locking or self.phase == .locked;
    }

    pub fn blanksOutput(self: Machine) bool {
        return self.phase == .locking or self.phase == .locked;
    }
};

/// Per-lock protocol object. A finished lock never owned the session.
pub const Object = struct {
    owns_session: bool = false,
    finished: bool = false,

    pub fn claim(self: *Object, machine: *Machine) error{AlreadyLocked}!void {
        machine.begin() catch {
            self.finished = true;
            return error.AlreadyLocked;
        };
        self.owns_session = true;
    }

    pub fn confirm(self: *Object, machine: *Machine) void {
        if (!self.owns_session or self.finished) return;
        machine.confirm();
    }

    pub fn unlock(self: *Object, machine: *Machine) error{InvalidUnlock}!void {
        if (self.finished or !self.owns_session) return error.InvalidUnlock;
        try machine.unlock();
        self.owns_session = false;
    }

    pub fn destroy(self: *Object, machine: *Machine) error{InvalidDestroy}!void {
        if (self.finished or !self.owns_session) return;
        try machine.destroy();
        self.owns_session = false;
    }

    pub fn resourceGone(self: *Object, machine: *Machine) void {
        if (self.finished or !self.owns_session) return;
        machine.clientDied();
        if (machine.phase == .idle) self.owns_session = false;
    }
};

test "lock machine blanks and drops input until unlock" {
    var machine = Machine{};
    try machine.begin();
    try testing.expect(machine.dropsInput());
    try testing.expect(machine.blanksOutput());
    machine.confirm();
    try testing.expectEqual(Phase.locked, machine.phase);
    try testing.expectError(error.InvalidDestroy, machine.destroy());
    try machine.unlock();
    try testing.expectEqual(Phase.idle, machine.phase);
    try testing.expectFalse(machine.dropsInput());
}

test "lock machine rejects a second lock and invalid unlock" {
    var machine = Machine{};
    try testing.expectError(error.InvalidUnlock, machine.unlock());
    try machine.begin();
    try testing.expectError(error.AlreadyLocked, machine.begin());
    machine.clientDied();
    try testing.expectEqual(Phase.idle, machine.phase);
}

test "client death while locked keeps the session locked" {
    var machine = Machine{};
    try machine.begin();
    machine.confirm();
    machine.clientDied();
    try testing.expectEqual(Phase.locked, machine.phase);
    try testing.expect(machine.abandoned);
    try testing.expect(machine.dropsInput());
    try machine.begin();
    try testing.expectEqual(Phase.locking, machine.phase);
    try testing.expect(machine.dropsInput());
    machine.confirm();
    try testing.expectEqual(Phase.locked, machine.phase);
    try testing.expectFalse(machine.abandoned);
}

test "locking death after abandon stays blanked" {
    var machine = Machine{};
    try machine.begin();
    machine.confirm();
    machine.clientDied();
    try machine.begin();
    machine.clientDied();
    try testing.expectEqual(Phase.locked, machine.phase);
    try testing.expect(machine.abandoned);
    try testing.expect(machine.dropsInput());
}

test "finished lock destroy leaves the owner locked" {
    var machine = Machine{};
    var owner = Object{};
    var extra = Object{};
    try owner.claim(&machine);
    owner.confirm(&machine);
    try testing.expectError(error.AlreadyLocked, extra.claim(&machine));
    try testing.expect(extra.finished);
    try extra.destroy(&machine);
    try testing.expectEqual(Phase.locked, machine.phase);
    try testing.expectError(error.InvalidUnlock, extra.unlock(&machine));
    try owner.unlock(&machine);
    try testing.expectEqual(Phase.idle, machine.phase);
}
