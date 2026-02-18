const { createWebRtcTransport } = require('./mediasoup');

class Room {
  constructor({ router, io }) {
    this.router = router;
    this.io = io;

    this.peers = new Map();
    this.producerToPeer = new Map();

    this.teacherId = null;
    this.teacherProducers = { audio: null, video: null };

    this.activeStudentId = null;
    this.activeStudentProducers = { audio: null, video: null };
  }

  log(event, payload) {
    const timestamp = new Date().toISOString();
    if (payload !== undefined) {
      console.log(`[${timestamp}] [room] ${event}`, payload);
      return;
    }
    console.log(`[${timestamp}] [room] ${event}`);
  }

  _normalizeKind(kind) {
    const value = String(kind || '').toLowerCase();
    if (value.includes('audio')) return 'audio';
    if (value.includes('video')) return 'video';
    throw new Error(`Unsupported media kind: ${kind}`);
  }

  _getPeerOrThrow(peerId) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      throw new Error(`Peer not found: ${peerId}`);
    }
    return peer;
  }

  _assertTeacher(peerId) {
    const peer = this._getPeerOrThrow(peerId);
    if (peer.role !== 'teacher') {
      throw new Error('Only teacher can perform this action');
    }
    if (this.teacherId !== peerId) {
      throw new Error('Teacher session is not active');
    }
    return peer;
  }

  _peerSummary(peer) {
    return {
      id: peer.id,
      role: peer.role,
      name: peer.name,
      isActiveSpeaker: peer.id === this.activeStudentId,
      joinedAt: peer.joinedAt
    };
  }

  _producerPayload(peer, producer) {
    return {
      producerId: producer.id,
      peerId: peer.id,
      role: peer.role,
      name: peer.name,
      kind: producer.kind,
      source: peer.role === 'teacher' ? 'teacher' : 'activeStudent'
    };
  }

  _broadcastPeers() {
    this.io.emit('peersUpdate', {
      peers: this.getPeersForClient(),
      teacherId: this.teacherId,
      activeStudentId: this.activeStudentId
    });
  }

  _getJoinProducers(currentPeerId) {
    const payload = [];

    for (const peer of this.peers.values()) {
      if (peer.id === currentPeerId) continue;

      for (const producer of peer.producers.values()) {
        payload.push(this._producerPayload(peer, producer));
      }
    }

    return payload;
  }

  _syncActiveStudentProducerSlots(peer) {
    this.activeStudentProducers = { audio: null, video: null };
    if (!peer) return;

    for (const producer of peer.producers.values()) {
      const normalizedKind = this._normalizeKind(producer.kind);
      this.activeStudentProducers[normalizedKind] = producer.id;
    }
  }

  _clearTeacherProducerSlot(kind, producerId) {
    if (this.teacherProducers[kind] === producerId) {
      this.teacherProducers[kind] = null;
    }
  }

  _clearActiveStudentProducerSlot(kind, producerId) {
    if (this.activeStudentProducers[kind] === producerId) {
      this.activeStudentProducers[kind] = null;
    }
  }

  getPeersForClient() {
    return Array.from(this.peers.values()).map((peer) => this._peerSummary(peer));
  }

  async joinPeer(socket, { role, name }) {
    const normalizedRole = String(role || '').toLowerCase();
    if (!['teacher', 'student'].includes(normalizedRole)) {
      throw new Error('role must be teacher or student');
    }

    if (normalizedRole === 'teacher' && this.teacherId && this.teacherId !== socket.id) {
      throw new Error('Teacher is already connected');
    }

    const peer = {
      id: socket.id,
      socket,
      role: normalizedRole,
      name: name || (normalizedRole === 'teacher' ? 'Teacher' : 'Student'),
      joinedAt: new Date().toISOString(),
      transports: new Map(),
      producers: new Map(),
      consumers: new Map()
    };

    this.peers.set(peer.id, peer);

    if (peer.role === 'teacher') {
      this.teacherId = peer.id;
    }

    this.log('joinRoom', { peerId: peer.id, role: peer.role, name: peer.name });
    this._broadcastPeers();

    return {
      peerId: peer.id,
      role: peer.role,
      name: peer.name,
      rtpCapabilities: this.router.rtpCapabilities,
      peers: this.getPeersForClient(),
      producers: this._getJoinProducers(peer.id),
      teacherId: this.teacherId,
      activeStudentId: this.activeStudentId
    };
  }

  async createTransport(peerId, direction) {
    const peer = this._getPeerOrThrow(peerId);

    if (!['send', 'recv'].includes(direction)) {
      throw new Error('direction must be send or recv');
    }

    const transport = await createWebRtcTransport(this.router);
    transport.appData = {
      peerId: peer.id,
      direction
    };

    peer.transports.set(transport.id, transport);

    this.log('createTransport', {
      peerId,
      direction,
      transportId: transport.id
    });

    return {
      id: transport.id,
      iceParameters: transport.iceParameters,
      iceCandidates: transport.iceCandidates,
      dtlsParameters: transport.dtlsParameters,
      sctpParameters: transport.sctpParameters
    };
  }

  async connectTransport(peerId, transportId, dtlsParameters) {
    const peer = this._getPeerOrThrow(peerId);
    const transport = peer.transports.get(transportId);

    if (!transport) {
      throw new Error(`Transport not found: ${transportId}`);
    }

    await transport.connect({ dtlsParameters });

    this.log('connectTransport', {
      peerId,
      transportId,
      direction: transport.appData?.direction
    });
  }

  async produce(peerId, transportId, kind, rtpParameters, appData = {}) {
    const peer = this._getPeerOrThrow(peerId);
    const transport = peer.transports.get(transportId);

    if (!transport) {
      throw new Error(`Transport not found: ${transportId}`);
    }

    if (transport.appData?.direction !== 'send') {
      throw new Error('Transport is not a send transport');
    }

    if (peer.role === 'student' && this.activeStudentId !== peer.id) {
      throw new Error('Student is not approved to speak right now');
    }

    const normalizedKind = this._normalizeKind(kind);

    for (const existingProducer of peer.producers.values()) {
      if (this._normalizeKind(existingProducer.kind) === normalizedKind) {
        await this.closeProducer(peer.id, existingProducer.id, { emit: true, shouldClose: true });
      }
    }

    const producer = await transport.produce({
      kind: normalizedKind,
      rtpParameters,
      appData: {
        ...appData,
        peerId: peer.id,
        role: peer.role,
        name: peer.name,
        kind: normalizedKind,
        source: peer.role === 'teacher' ? 'teacher' : 'activeStudent'
      }
    });

    peer.producers.set(producer.id, producer);
    this.producerToPeer.set(producer.id, peer.id);

    if (peer.role === 'teacher') {
      this.teacherProducers[normalizedKind] = producer.id;
    }

    if (peer.role === 'student' && this.activeStudentId === peer.id) {
      this.activeStudentProducers[normalizedKind] = producer.id;
    }

    producer.on('transportclose', () => {
      this.closeProducer(peer.id, producer.id, { emit: true, shouldClose: false }).catch((error) => {
        this.log('producer transportclose cleanup failed', { producerId: producer.id, error: error.message });
      });
    });

    this.log('produce', {
      peerId: peer.id,
      role: peer.role,
      kind: normalizedKind,
      producerId: producer.id
    });

    peer.socket.broadcast.emit('newProducer', this._producerPayload(peer, producer));

    return { id: producer.id };
  }

  async consume(peerId, transportId, producerId, rtpCapabilities) {
    const consumerPeer = this._getPeerOrThrow(peerId);
    const transport = consumerPeer.transports.get(transportId);

    if (!transport) {
      throw new Error(`Transport not found: ${transportId}`);
    }

    if (transport.appData?.direction !== 'recv') {
      throw new Error('Transport is not a recv transport');
    }

    const producerPeerId = this.producerToPeer.get(producerId);
    if (!producerPeerId) {
      throw new Error(`Producer not found: ${producerId}`);
    }

    const producerPeer = this._getPeerOrThrow(producerPeerId);
    const producer = producerPeer.producers.get(producerId);
    if (!producer) {
      throw new Error(`Producer not found: ${producerId}`);
    }

    if (!this.router.canConsume({ producerId: producer.id, rtpCapabilities })) {
      throw new Error('router.canConsume returned false');
    }

    const consumer = await transport.consume({
      producerId: producer.id,
      rtpCapabilities,
      paused: true,
      appData: {
        peerId: producerPeer.id,
        role: producerPeer.role,
        name: producerPeer.name,
        kind: producer.kind,
        source: producerPeer.role === 'teacher' ? 'teacher' : 'activeStudent'
      }
    });

    consumerPeer.consumers.set(consumer.id, consumer);

    consumer.on('transportclose', () => {
      consumerPeer.consumers.delete(consumer.id);
    });

    consumer.on('producerclose', () => {
      consumerPeer.consumers.delete(consumer.id);
      consumerPeer.socket.emit('consumerClosed', {
        consumerId: consumer.id,
        producerId: producer.id
      });
    });

    this.log('consume', {
      peerId,
      transportId,
      producerId,
      consumerId: consumer.id
    });

    return {
      id: consumer.id,
      producerId: producer.id,
      peerId: producerPeer.id,
      kind: consumer.kind,
      rtpParameters: consumer.rtpParameters,
      type: consumer.type,
      producerPaused: consumer.producerPaused,
      appData: consumer.appData
    };
  }

  async resumeConsumer(peerId, consumerId) {
    const peer = this._getPeerOrThrow(peerId);
    const consumer = peer.consumers.get(consumerId);

    if (!consumer) {
      throw new Error(`Consumer not found: ${consumerId}`);
    }

    await consumer.resume();

    this.log('resumeConsumer', {
      peerId,
      consumerId
    });
  }

  async closeProducer(peerId, producerId, { emit = true, shouldClose = true } = {}) {
    const peer = this.peers.get(peerId);
    if (!peer) return;

    const producer = peer.producers.get(producerId);
    if (!producer) return;

    peer.producers.delete(producerId);
    this.producerToPeer.delete(producerId);

    const normalizedKind = this._normalizeKind(producer.kind);

    if (peer.role === 'teacher') {
      this._clearTeacherProducerSlot(normalizedKind, producer.id);
    }

    if (peer.role === 'student' && this.activeStudentId === peer.id) {
      this._clearActiveStudentProducerSlot(normalizedKind, producer.id);
    }

    if (shouldClose && !producer.closed) {
      producer.close();
    }

    if (emit) {
      this.io.emit('producerClosed', {
        producerId,
        peerId: peer.id,
        role: peer.role,
        name: peer.name,
        kind: normalizedKind,
        source: peer.role === 'teacher' ? 'teacher' : 'activeStudent'
      });
    }

    this.log('closeProducer', {
      peerId,
      producerId,
      kind: normalizedKind
    });
  }

  async approveTurn(teacherPeerId, studentId) {
    this._assertTeacher(teacherPeerId);

    const studentPeer = this._getPeerOrThrow(studentId);
    if (studentPeer.role !== 'student') {
      throw new Error('approveTurn target must be a student');
    }

    if (this.activeStudentId && this.activeStudentId !== studentId) {
      await this._endActiveTurnInternal('replaced_by_teacher');
    }

    this.activeStudentId = studentId;
    this._syncActiveStudentProducerSlots(studentPeer);

    studentPeer.socket.emit('turnApproved', {
      studentId,
      approvedBy: teacherPeerId
    });

    this.io.emit('activeStudentChanged', {
      studentId,
      reason: 'approved'
    });

    this._broadcastPeers();

    this.log('approveTurn', {
      teacherPeerId,
      studentId
    });

    return {
      activeStudentId: this.activeStudentId
    };
  }

  async endTurn(teacherPeerId, reason = 'ended_by_teacher') {
    this._assertTeacher(teacherPeerId);
    await this._endActiveTurnInternal(reason);
    return { activeStudentId: this.activeStudentId };
  }

  async _endActiveTurnInternal(reason) {
    if (!this.activeStudentId) {
      return;
    }

    const studentId = this.activeStudentId;
    const studentPeer = this.peers.get(studentId);

    this.activeStudentId = null;
    this.activeStudentProducers = { audio: null, video: null };

    if (studentPeer) {
      const producerIds = Array.from(studentPeer.producers.keys());
      for (const producerId of producerIds) {
        await this.closeProducer(studentPeer.id, producerId, { emit: true, shouldClose: true });
      }

      studentPeer.socket.emit('turnEnded', {
        studentId,
        reason
      });
    }

    this.io.emit('activeStudentChanged', {
      studentId: null,
      reason
    });

    this._broadcastPeers();

    this.log('turnEnded', {
      studentId,
      reason
    });
  }

  async removePeer(peerId) {
    const peer = this.peers.get(peerId);
    if (!peer) return;

    this.log('disconnect', {
      peerId,
      role: peer.role,
      name: peer.name
    });

    const isTeacher = this.teacherId === peerId;
    const isActiveStudent = this.activeStudentId === peerId;

    const producerIds = Array.from(peer.producers.keys());
    for (const producerId of producerIds) {
      await this.closeProducer(peer.id, producerId, { emit: true, shouldClose: true });
    }

    for (const consumer of peer.consumers.values()) {
      consumer.close();
    }
    peer.consumers.clear();

    for (const transport of peer.transports.values()) {
      transport.close();
    }
    peer.transports.clear();

    this.peers.delete(peerId);

    if (isActiveStudent) {
      this.activeStudentId = null;
      this.activeStudentProducers = { audio: null, video: null };
      this.io.emit('activeStudentChanged', {
        studentId: null,
        reason: 'student_disconnected'
      });
    }

    if (isTeacher) {
      this.teacherId = null;
      this.teacherProducers = { audio: null, video: null };
      this.io.emit('teacherDisconnected', {
        teacherId: peerId
      });

      if (this.activeStudentId) {
        await this._endActiveTurnInternal('teacher_disconnected');
      }
    }

    this._broadcastPeers();
  }

  getHealth() {
    return {
      ok: true,
      peersCount: this.peers.size,
      teacherId: this.teacherId,
      activeStudentId: this.activeStudentId,
      teacherProducers: { ...this.teacherProducers },
      activeStudentProducers: { ...this.activeStudentProducers },
      timestamp: new Date().toISOString()
    };
  }

  getPeersForApi() {
    return Array.from(this.peers.values()).map((peer) => ({
      id: peer.id,
      role: peer.role,
      name: peer.name,
      joinedAt: peer.joinedAt,
      transportCount: peer.transports.size,
      producerCount: peer.producers.size,
      consumerCount: peer.consumers.size,
      isActiveSpeaker: peer.id === this.activeStudentId
    }));
  }

  getTeacherProducersState() {
    return {
      teacherId: this.teacherId,
      producers: { ...this.teacherProducers }
    };
  }

  getActiveStudentState() {
    return {
      activeStudentId: this.activeStudentId,
      producers: { ...this.activeStudentProducers }
    };
  }
}

module.exports = Room;
