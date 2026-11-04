(function () {
  "use strict";

  const i18n = window.MZRacingI18n;
  const elements = {
    lobby: document.getElementById("lobby"),
    close: document.getElementById("closeButton"),
    filters: document.getElementById("filters"),
    catalogStatus: document.getElementById("catalogStatus"),
    list: document.getElementById("raceList"),
    detail: document.getElementById("raceDetail"),
    organizer: document.getElementById("organizer"),
    organizerClose: document.getElementById("organizerCloseButton"),
    organizerTabs: document.getElementById("organizerTabs"),
    organizerSearch: document.getElementById("organizerSearch"),
    organizerSearchInput: document.getElementById("organizerSearchInput"),
    organizerStatus: document.getElementById("organizerStatus"),
    organizerList: document.getElementById("organizerList"),
    organizerDetail: document.getElementById("organizerDetail"),
    organizerPrevious: document.getElementById("organizerPrevious"),
    organizerNext: document.getElementById("organizerNext"),
    organizerPage: document.getElementById("organizerPage"),
    hud: document.getElementById("raceHud"),
    hudPhase: document.getElementById("hudPhase"),
    hudTime: document.getElementById("hudTime"),
    hudCheckpoint: document.getElementById("hudCheckpoint"),
    hudRoute: document.getElementById("hudRoute"),
    results: document.getElementById("results"),
    resultTitle: document.getElementById("resultTitle"),
    resultList: document.getElementById("resultList"),
    resultExpiry: document.getElementById("resultExpiry"),
    toast: document.getElementById("toast")
  };

  const state = {
    open: false,
    filter: "all",
    catalog: [],
    catalogWarning: null,
    selectedId: null,
    detail: null,
    pending: new Map(),
    generation: 0,
    requestTimeoutMs: 6000,
    lastSeq: 0,
    runtime: null,
    runtimeReceivedAt: 0,
    toastTimer: null,
    organizer: {
      open: false, tab: "sessions", sessions: [], routes: [], detail: null,
      selectedId: null, page: 1, hasNext: false, search: "", refreshMs: 3000,
      nextRefreshAt: 0, routesError: null, loading: false
    }
  };

  function resourceName() {
    return typeof GetParentResourceName === "function" ? GetParentResourceName() : "mz_racing";
  }

  function post(endpoint, body) {
    if (window.MZRacingFixture && typeof window.MZRacingFixture.post === "function") {
      return window.MZRacingFixture.post(endpoint, body);
    }
    return fetch(`https://${resourceName()}/${endpoint}`, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=UTF-8" },
      body: JSON.stringify(body || {})
    }).then((response) => response.json());
  }

  function requestId(action) {
    state.generation += 1;
    return `${action}:${Date.now()}:${state.generation}`;
  }

  function setPending(action, id, button) {
    const previous = state.pending.get(action);
    if (previous) clearTimeout(previous.timer);
    if (button) button.disabled = true;
    const timer = setTimeout(() => {
      const current = state.pending.get(action);
      if (!current || current.id !== id) return;
      state.pending.delete(action);
      if (button) button.disabled = false;
      if (action === "organizer:list" || action === "organizer:routes") {
        state.organizer.loading = false;
        renderOrganizer();
      }
      showToast(i18n.t("request_timeout"), true);
    }, state.requestTimeoutMs);
    state.pending.set(action, { id, timer, button });
  }

  function clearPending(action, id) {
    const current = state.pending.get(action);
    if (!current || (id && current.id !== id)) return false;
    clearTimeout(current.timer);
    if (current.button) current.button.disabled = false;
    state.pending.delete(action);
    return true;
  }

  function request(action, payload, button) {
    const id = requestId(action);
    setPending(action, id, button);
    post("racingRequest", { action, payload: payload || {}, requestId: id })
      .then((result) => {
        if (!result || result.ok !== true) {
          clearPending(action, id);
          showToast(i18n.t((result && result.error) || "requestFailed"), true);
        }
      })
      .catch(() => {
        clearPending(action, id);
        showToast(i18n.t("requestFailed"), true);
      });
    return id;
  }

  function organizerRequest(action, payload, button) {
    const key = `organizer:${action}`;
    if (state.pending.has(key)) return null;
    const id = requestId(key);
    setPending(key, id, button);
    post("racingOrganizerRequest", { action, payload: payload || {}, requestId: id })
      .then((result) => {
        if (!result || result.ok !== true) {
          clearPending(key, id);
          if (action === "list" || action === "routes") state.organizer.loading = false;
          renderOrganizer();
          showToast(i18n.t((result && result.error) || "requestFailed"), true);
        }
      })
      .catch(() => {
        clearPending(key, id);
        if (action === "list" || action === "routes") state.organizer.loading = false;
        renderOrganizer();
        showToast(i18n.t("requestFailed"), true);
      });
    return id;
  }

  function showToast(message, error) {
    clearTimeout(state.toastTimer);
    elements.toast.textContent = message;
    elements.toast.classList.toggle("is-error", error === true);
    elements.toast.classList.add("is-visible");
    elements.toast.setAttribute("aria-hidden", "false");
    state.toastTimer = setTimeout(() => {
      elements.toast.classList.remove("is-visible");
      elements.toast.setAttribute("aria-hidden", "true");
    }, 3200);
  }

  function formatTime(milliseconds) {
    const value = Math.max(0, Number(milliseconds) || 0);
    const minutes = Math.floor(value / 60000);
    const seconds = Math.floor((value % 60000) / 1000);
    const millis = Math.floor(value % 1000);
    return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}.${String(millis).padStart(3, "0")}`;
  }

  function formatShortDuration(milliseconds) {
    const totalSeconds = Math.max(0, Math.ceil((Number(milliseconds) || 0) / 1000));
    const minutes = Math.floor(totalSeconds / 60);
    return minutes > 0 ? `${minutes} min` : `${totalSeconds} s`;
  }

  function stateLabel(value) {
    return i18n.t(value || "failed");
  }

  function matchesFilter(session) {
    if (state.filter === "all") return true;
    if (state.filter === "running") return session.state === "countdown" || session.state === "running";
    if (state.filter === "finished") return ["finished", "cancelled", "failed"].includes(session.state);
    return session.state === state.filter;
  }

  function renderCatalog() {
    elements.list.replaceChildren();
    const sessions = state.catalog.filter(matchesFilter);
    elements.catalogStatus.textContent = state.catalogWarning
      ? i18n.t(state.catalogWarning)
      : (sessions.length ? "" : i18n.t("empty"));
    sessions.forEach((session) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "race-card";
      button.classList.toggle("is-selected", session.sessionId === state.selectedId);
      button.dataset.sessionId = session.sessionId;

      const top = document.createElement("div");
      top.className = "race-card__top";
      const title = document.createElement("h3");
      title.textContent = session.title || session.route?.title || session.sessionId;
      const status = document.createElement("span");
      status.className = "status";
      status.dataset.state = session.state;
      status.textContent = stateLabel(session.state);
      top.append(title, status);

      const meta = document.createElement("div");
      meta.className = "race-card__meta";
      const drivers = document.createElement("span");
      drivers.textContent = i18n.t("participants", { count: session.participantCount || 0, max: session.maxParticipants || 0 });
      const checkpoints = document.createElement("span");
      checkpoints.textContent = i18n.t("checkpoints", { count: session.route?.checkpointCount || 0 });
      meta.append(drivers, checkpoints);
      button.append(top, meta);
      button.addEventListener("click", () => selectSession(session.sessionId));
      elements.list.append(button);
    });
  }

  function stat(label, value) {
    const item = document.createElement("div");
    item.className = "detail-stat";
    const name = document.createElement("span");
    name.textContent = label;
    const data = document.createElement("strong");
    data.textContent = value;
    item.append(name, data);
    return item;
  }

  function actionButton(label, className, handler, disabled) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `action ${className || ""}`.trim();
    button.textContent = label;
    button.disabled = disabled === true;
    button.addEventListener("click", () => handler(button));
    return button;
  }

  function reasonText(detail) {
    const reason = detail.joinReason || detail.observeReason;
    if (!reason) return "";
    if (reason === "session_full") return i18n.t("full");
    return i18n.t(reason);
  }

  function renderDetail() {
    elements.detail.replaceChildren();
    const detail = state.detail;
    if (!detail || detail.sessionId !== state.selectedId) {
      const empty = document.createElement("div");
      empty.className = "detail-empty";
      empty.textContent = i18n.t("selectRace");
      elements.detail.append(empty);
      return;
    }

    const status = document.createElement("p");
    status.className = "status";
    status.dataset.state = detail.state;
    status.textContent = stateLabel(detail.state);
    const title = document.createElement("h2");
    title.className = "detail-title";
    title.textContent = detail.title;
    const description = document.createElement("p");
    description.className = "detail-description";
    description.textContent = detail.route?.description || i18n.t("selectRace");

    const grid = document.createElement("div");
    grid.className = "detail-grid";
    const distance = Number(detail.route?.totalDistance || 0) / 1000;
    const distanceText = new Intl.NumberFormat(i18n.getLocale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(distance);
    grid.append(
      stat(i18n.t("checkpointsLabel"), String(detail.route?.checkpointCount || 0)),
      stat(i18n.t("driversLabel"), `${detail.participantCount || 0} / ${detail.maxParticipants || 0}`),
      stat(i18n.t("typeLabel"), String(detail.route?.routeType || "generic").toUpperCase()),
      stat(i18n.t("distanceLabel"), i18n.t("distance", { value: distanceText }))
    );

    const actions = document.createElement("div");
    actions.className = "detail-actions";
    if (detail.canLeave) {
      actions.append(actionButton(i18n.t("leave"), "action--danger", (button) => {
        if (window.confirm(i18n.t("confirmLeave"))) request("leave", { sessionId: detail.sessionId }, button);
      }));
    } else {
      actions.append(
        actionButton(i18n.t("enter"), "action--primary", (button) => request("join", { sessionId: detail.sessionId, role: "participant" }, button), !detail.canJoin),
        actionButton(i18n.t("observe"), "", (button) => request("join", { sessionId: detail.sessionId, role: "observer" }, button), !detail.canObserve)
      );
    }
    const hint = document.createElement("p");
    hint.className = "action-hint";
    hint.textContent = reasonText(detail);
    actions.append(hint);
    elements.detail.append(status, title, description, grid, actions);
  }

  function selectSession(sessionId) {
    state.selectedId = sessionId;
    state.detail = null;
    renderCatalog();
    renderDetail();
    request("detail", { sessionId });
  }

  function organizerLoadPage() {
    const organizer = state.organizer;
    const action = organizer.tab === "routes" ? "routes" : "list";
    if (organizerRequest(action, { page: organizer.page, search: organizer.search })) {
      organizer.loading = true;
      renderOrganizer();
    }
  }

  function organizerSelect(item) {
    const organizer = state.organizer;
    organizer.selectedId = organizer.tab === "routes" ? item.publicId : item.sessionId;
    organizer.detail = organizer.tab === "routes" ? item : null;
    renderOrganizer();
    if (organizer.tab === "sessions") organizerRequest("detail", { sessionId: item.sessionId });
  }

  function organizerCard(item) {
    const organizer = state.organizer;
    const routeMode = organizer.tab === "routes";
    const id = routeMode ? item.publicId : item.sessionId;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "race-card";
    button.classList.toggle("is-selected", id === organizer.selectedId);
    button.dataset.organizerId = id;
    const top = document.createElement("div");
    top.className = "race-card__top";
    const title = document.createElement("h3");
    title.textContent = item.route?.title || item.title || item.publicId;
    const status = document.createElement("span");
    status.className = "status";
    status.dataset.state = routeMode ? "published" : item.state;
    status.textContent = routeMode ? String(item.routeType || "generic").toUpperCase() : stateLabel(item.state);
    top.append(title, status);
    const meta = document.createElement("div");
    meta.className = "race-card__meta";
    const first = document.createElement("span");
    first.textContent = routeMode
      ? i18n.t("checkpoints", { count: item.checkpointCount || 0 })
      : i18n.t("participants", { count: item.participantCount || 0, max: item.maxParticipants || 0 });
    const second = document.createElement("span");
    second.textContent = routeMode
      ? `${i18n.t("revisionLabel")} ${item.revision || 0}`
      : `${i18n.t("revisionLabel")} ${item.revision || 0}`;
    meta.append(first, second);
    button.append(top, meta);
    button.addEventListener("click", () => organizerSelect(item));
    return button;
  }

  function renderOrganizerDetail() {
    const container = elements.organizerDetail;
    container.replaceChildren();
    const organizer = state.organizer;
    const detail = organizer.detail;
    if (!detail) {
      const empty = document.createElement("div");
      empty.className = "detail-empty";
      empty.textContent = i18n.t("organizerSelect");
      container.append(empty);
      return;
    }

    const routeMode = organizer.tab === "routes";
    const status = document.createElement("p");
    status.className = "status";
    status.dataset.state = routeMode ? "published" : detail.state;
    status.textContent = routeMode ? String(detail.routeType || "generic").toUpperCase() : stateLabel(detail.state);
    const title = document.createElement("h2");
    title.className = "detail-title";
    title.textContent = routeMode ? detail.title : detail.route?.title;
    const description = document.createElement("p");
    description.className = "detail-description";
    description.textContent = routeMode ? (detail.description || "") : (detail.route?.description || "");
    const grid = document.createElement("div");
    grid.className = "detail-grid";
    const route = routeMode ? detail : (detail.route || {});
    grid.append(
      stat(i18n.t("checkpointsLabel"), String(route.checkpointCount || 0)),
      stat(i18n.t("revisionLabel"), String(route.revision || detail.revision || 0)),
      stat(i18n.t("typeLabel"), String(route.routeType || "generic").toUpperCase()),
      stat(i18n.t(routeMode ? "distanceLabel" : "driversLabel"), routeMode
        ? i18n.t("distance", { value: (Number(route.totalDistance || 0) / 1000).toFixed(1) })
        : `${detail.participantCount || 0} / ${detail.maxParticipants || 0}`)
    );
    const actions = document.createElement("div");
    actions.className = "detail-actions";
    if (routeMode) {
      actions.append(actionButton(i18n.t("createSession"), "action--primary", (button) => {
        organizerRequest("create", { routePublicId: detail.publicId, routeRevision: detail.revision }, button);
      }));
    } else {
      if (detail.canOpenRegistration) {
        actions.append(actionButton(i18n.t("openRegistration"), "action--primary", (button) => {
          organizerRequest("openRegistration", { sessionId: detail.sessionId }, button);
        }));
      }
      if (detail.canStart) {
        actions.append(actionButton(i18n.t("startRace"), "action--primary", (button) => {
          organizerRequest("start", { sessionId: detail.sessionId }, button);
        }));
      }
      if (detail.canCancel) {
        actions.append(actionButton(i18n.t("cancelRace"), "action--danger", (button) => {
          if (window.confirm(i18n.t("confirmCancel"))) organizerRequest("cancel", { sessionId: detail.sessionId }, button);
        }));
      }
    }
    container.append(status, title, description, grid, actions);

    if (!routeMode) {
      const heading = document.createElement("h3");
      heading.className = "participant-heading";
      heading.textContent = i18n.t("participantsTitle");
      const participants = document.createElement("div");
      participants.className = "participant-list";
      const rows = Array.isArray(detail.participants) ? detail.participants : [];
      if (!rows.length) {
        const empty = document.createElement("p");
        empty.className = "state-block";
        empty.textContent = i18n.t("noParticipants");
        participants.append(empty);
      }
      rows.forEach((participant) => {
        const row = document.createElement("div");
        row.className = "participant-row";
        const name = document.createElement("strong");
        name.textContent = participant.label;
        const progress = document.createElement("span");
        progress.textContent = participant.finishTimeMs != null
          ? `${participant.finishPosition ? `#${participant.finishPosition} · ` : ""}${formatTime(participant.finishTimeMs)}`
          : `${Math.max(0, Number(participant.nextCheckpoint || 1) - 1)} / ${route.checkpointCount || 0}`;
        const participantStatus = document.createElement("span");
        participantStatus.className = "status";
        participantStatus.dataset.state = participant.status;
        participantStatus.textContent = participant.role === "observer" ? i18n.t("observe") : String(participant.status || "");
        row.append(name, progress, participantStatus);
        participants.append(row);
      });
      container.append(heading, participants);
      if (["finished", "cancelled", "failed"].includes(detail.state)) {
        const temporary = document.createElement("p");
        temporary.className = "action-hint";
        temporary.textContent = i18n.t("temporaryResults");
        container.append(temporary);
      }
    }
  }

  function renderOrganizer() {
    const organizer = state.organizer;
    const items = organizer.tab === "routes" ? organizer.routes : organizer.sessions;
    elements.organizerList.replaceChildren(...items.map(organizerCard));
    elements.organizerStatus.textContent = organizer.loading
      ? i18n.t("organizerLoading")
      : organizer.tab === "routes" && organizer.routesError
      ? i18n.t(organizer.routesError)
      : (items.length ? "" : i18n.t(organizer.tab === "routes" ? "noRoutes" : "noSessions"));
    elements.organizerPage.textContent = i18n.t("page", { page: organizer.page });
    elements.organizerPrevious.disabled = organizer.page <= 1;
    elements.organizerNext.disabled = !organizer.hasNext;
    elements.organizerTabs.querySelectorAll("[data-organizer-tab]").forEach((button) => {
      button.classList.toggle("is-active", button.dataset.organizerTab === organizer.tab);
    });
    renderOrganizerDetail();
  }

  function renderResults(results, session) {
    const visible = Boolean(results && Array.isArray(results.entries) && results.entries.length > 0);
    elements.results.classList.toggle("is-visible", visible);
    elements.results.setAttribute("aria-hidden", String(!visible));
    if (!visible) return;
    elements.resultTitle.textContent = session?.title || i18n.t("resultTitle");
    elements.resultList.replaceChildren();
    results.entries.forEach((entry) => {
      const row = document.createElement("li");
      row.className = "result-row";
      row.classList.toggle("is-own", entry.own === true);
      const position = document.createElement("span");
      position.className = "result-position";
      position.textContent = entry.position ? String(entry.position).padStart(2, "0") : "--";
      const name = document.createElement("span");
      name.className = "result-name";
      name.textContent = entry.label;
      if (entry.own) {
        const own = document.createElement("small");
        own.className = "result-own";
        own.textContent = i18n.t("own");
        name.append(own);
      }
      const time = document.createElement("span");
      time.className = "result-time";
      time.textContent = entry.finishTimeMs == null ? i18n.t("dnf") : formatTime(entry.finishTimeMs);
      row.append(position, name, time);
      elements.resultList.append(row);
    });
    elements.resultExpiry.textContent = results.expiresInMs == null ? "" : i18n.t("resultExpires", { time: formatShortDuration(results.expiresInMs) });
  }

  function renderRuntime(data) {
    state.runtime = data;
    state.runtimeReceivedAt = performance.now();
    const session = data.session || {};
    const participant = data.participant || {};
    const hudVisible = participant.role === "participant" && participant.status === "active"
      && (session.state === "countdown" || session.state === "running");
    elements.hud.classList.toggle("is-visible", hudVisible);
    elements.hud.setAttribute("aria-hidden", String(!hudVisible));
    elements.hudPhase.textContent = i18n.t(session.state === "countdown" ? "phaseCountdown" : "phaseRunning");
    elements.hudRoute.textContent = session.title || session.route?.title || "";
    const checkpoint = data.nextCheckpoint;
    elements.hudCheckpoint.textContent = checkpoint
      ? i18n.t("checkpoint", { current: checkpoint.index, total: checkpoint.total })
      : i18n.t("checkpoint", { current: Math.max(0, (participant.nextCheckpoint || 1) - 1), total: session.route?.checkpointCount || 0 });
    renderResults(data.results, session);
  }

  function updateClock() {
    const runtime = state.runtime;
    if (!runtime || !runtime.session) return;
    const elapsedSincePush = performance.now() - state.runtimeReceivedAt;
    const session = runtime.session;
    if (session.state === "countdown") {
      elements.hudTime.textContent = formatTime(Math.max(0, (session.countdownRemainingMs || 0) - elapsedSincePush));
    } else {
      elements.hudTime.textContent = formatTime((session.elapsedMs || 0) + elapsedSincePush);
    }
  }

  function handleResponse(payload) {
    const seq = Number(payload.seq) || 0;
    if (seq && seq <= state.lastSeq) return;
    if (seq) state.lastSeq = seq;
    const pending = state.pending.get(payload.action);
    if (pending && payload.requestId !== pending.id) return;
    clearPending(payload.action, payload.requestId);

    if (payload.ok !== true) {
      showToast(i18n.t(payload.error || "requestFailed"), true);
      if (payload.action === "detail" && payload.error === "session_not_found") {
        state.detail = null;
        renderDetail();
      }
      return;
    }
    if (payload.action === "catalog" && payload.data) {
      state.catalog = Array.isArray(payload.data.sessions) ? payload.data.sessions : [];
      state.catalogWarning = payload.data.warning || null;
      renderCatalog();
    } else if (payload.action === "detail" && payload.data) {
      state.detail = payload.data;
      renderDetail();
    } else if (payload.action === "join") {
      showToast(i18n.t(payload.participant?.role === "observer" ? "observing" : "joined"));
      request("catalog", { page: 1, state: state.filter });
      if (state.selectedId) request("detail", { sessionId: state.selectedId });
    } else if (payload.action === "leave") {
      showToast(i18n.t("left"));
      request("catalog", { page: 1, state: state.filter });
      if (state.selectedId) request("detail", { sessionId: state.selectedId });
    }
  }

  function applyOrganizerCollection(kind, data) {
    const organizer = state.organizer;
    const items = Array.isArray(data?.[kind]) ? data[kind] : [];
    organizer[kind] = items;
    organizer.page = Number(data?.page) || 1;
    organizer.hasNext = data?.hasNext === true;
  }

  function handleOrganizerResponse(payload) {
    const seq = Number(payload.seq) || 0;
    if (seq && seq <= state.lastSeq) return;
    if (seq) state.lastSeq = seq;
    const pending = state.pending.get(payload.action);
    if (pending && payload.requestId !== pending.id) return;
    clearPending(payload.action, payload.requestId);

    const action = String(payload.action || "").replace("organizer:", "");
    if (action === "list" || action === "routes") state.organizer.loading = false;
    if (payload.ok !== true) {
      showToast(i18n.t(payload.error || "requestFailed"), true);
      if (payload.error === "route_revision_conflict" || payload.error === "route_not_found") {
        state.organizer.detail = null;
        organizerRequest("routes", { page: state.organizer.page, search: state.organizer.search });
      }
      renderOrganizer();
      return;
    }

    if (action === "bootstrap") {
      applyOrganizerCollection("sessions", payload.data?.sessions);
      state.organizer.routes = Array.isArray(payload.data?.routes?.routes) ? payload.data.routes.routes : [];
      state.organizer.routesError = payload.data?.routesError || null;
    } else if (action === "list") {
      applyOrganizerCollection("sessions", payload.data);
    } else if (action === "routes") {
      applyOrganizerCollection("routes", payload.data);
      state.organizer.routesError = null;
    } else if (action === "detail") {
      state.organizer.detail = payload.data;
      state.organizer.selectedId = payload.data?.sessionId || null;
    } else if (["create", "openRegistration", "start", "cancel"].includes(action)) {
      state.organizer.tab = "sessions";
      state.organizer.page = 1;
      state.organizer.detail = payload.data;
      state.organizer.selectedId = payload.data?.sessionId || null;
      showToast(i18n.t(action === "create" ? "sessionCreated" : "operationComplete"));
      organizerRequest("list", { page: 1, search: state.organizer.search });
    }
    state.organizer.nextRefreshAt = Date.now() + state.organizer.refreshMs;
    renderOrganizer();
  }

  function open(data) {
    i18n.set(data.locale);
    state.open = true;
    state.requestTimeoutMs = Number(data.requestTimeoutMs) || 6000;
    state.catalog = Array.isArray(data.catalog?.sessions) ? data.catalog.sessions : [];
    state.catalogWarning = data.catalog?.warning || null;
    elements.lobby.classList.add("is-visible");
    elements.lobby.setAttribute("aria-hidden", "false");
    renderCatalog();
    renderDetail();
  }

  function openOrganizer(data) {
    i18n.set(data.locale);
    const organizer = state.organizer;
    organizer.open = true;
    organizer.tab = "sessions";
    organizer.page = 1;
    organizer.search = "";
    organizer.selectedId = null;
    organizer.detail = null;
    organizer.refreshMs = Math.max(1000, Number(data.refreshMs) || 3000);
    organizer.nextRefreshAt = Date.now() + organizer.refreshMs;
    state.requestTimeoutMs = Number(data.requestTimeoutMs) || 6000;
    applyOrganizerCollection("sessions", data.bootstrap?.sessions);
    organizer.routes = Array.isArray(data.bootstrap?.routes?.routes) ? data.bootstrap.routes.routes : [];
    organizer.routesError = data.bootstrap?.routesError || null;
    organizer.loading = false;
    elements.organizerSearchInput.value = "";
    elements.organizer.classList.add("is-visible");
    elements.organizer.setAttribute("aria-hidden", "false");
    renderOrganizer();
  }

  function close() {
    state.open = false;
    state.organizer.open = false;
    elements.lobby.classList.remove("is-visible");
    elements.lobby.setAttribute("aria-hidden", "true");
    elements.organizer.classList.remove("is-visible");
    elements.organizer.setAttribute("aria-hidden", "true");
    state.pending.forEach((entry) => clearTimeout(entry.timer));
    state.pending.clear();
  }

  window.addEventListener("message", (event) => {
    const message = event.data || {};
    if (message.action === "racing:open") open(message.data || {});
    else if (message.action === "racing:organizerOpen") openOrganizer(message.data || {});
    else if (message.action === "racing:close") close();
    else if (message.action === "racing:response") handleResponse(message.data || {});
    else if (message.action === "racing:organizerResponse") handleOrganizerResponse(message.data || {});
    else if (message.action === "racing:state") renderRuntime(message.data || {});
    else if (message.action === "racing:runtimeReset") {
      state.runtime = null;
      elements.hud.classList.remove("is-visible");
      elements.results.classList.remove("is-visible");
    }
  });

  elements.close.addEventListener("click", () => post("racingClose", {}).finally(close));
  elements.organizerClose.addEventListener("click", () => post("racingClose", {}).finally(close));
  elements.filters.addEventListener("click", (event) => {
    const button = event.target.closest("[data-filter]");
    if (!button) return;
    state.filter = button.dataset.filter;
    elements.filters.querySelectorAll(".filter").forEach((item) => item.classList.toggle("is-active", item === button));
    renderCatalog();
  });
  elements.organizerTabs.addEventListener("click", (event) => {
    const button = event.target.closest("[data-organizer-tab]");
    if (!button) return;
    const organizer = state.organizer;
    organizer.tab = button.dataset.organizerTab;
    organizer.page = 1;
    organizer.selectedId = null;
    organizer.detail = null;
    renderOrganizer();
    organizerLoadPage();
  });
  elements.organizerSearch.addEventListener("submit", (event) => {
    event.preventDefault();
    state.organizer.search = elements.organizerSearchInput.value.trim();
    state.organizer.page = 1;
    state.organizer.selectedId = null;
    state.organizer.detail = null;
    renderOrganizer();
    organizerLoadPage();
  });
  elements.organizerPrevious.addEventListener("click", () => {
    if (state.organizer.page <= 1) return;
    state.organizer.page -= 1;
    organizerLoadPage();
  });
  elements.organizerNext.addEventListener("click", () => {
    if (!state.organizer.hasNext) return;
    state.organizer.page += 1;
    organizerLoadPage();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && (state.open || state.organizer.open)) post("racingClose", {}).finally(close);
  });

  setInterval(updateClock, 50);
  setInterval(() => {
    const organizer = state.organizer;
    if (!organizer.open || Date.now() < organizer.nextRefreshAt) return;
    organizer.nextRefreshAt = Date.now() + organizer.refreshMs;
    organizerLoadPage();
    if (organizer.tab === "sessions" && organizer.selectedId) {
      organizerRequest("detail", { sessionId: organizer.selectedId });
    }
  }, 500);
  post("racingReady", {}).then((result) => {
    if (result?.locale) i18n.set(result.locale);
    if (result?.requestTimeoutMs) state.requestTimeoutMs = Number(result.requestTimeoutMs);
  }).catch(() => {});

  window.MZRacingApp = {
    snapshot: () => ({
      open: state.open,
      filter: state.filter,
      selectedId: state.selectedId,
      pending: Array.from(state.pending.keys()),
      catalogSize: state.catalog.length,
      runtime: state.runtime,
      organizer: {
        open: state.organizer.open,
        tab: state.organizer.tab,
        page: state.organizer.page,
        selectedId: state.organizer.selectedId,
        sessionCount: state.organizer.sessions.length,
        routeCount: state.organizer.routes.length
      }
    })
  };
})();
