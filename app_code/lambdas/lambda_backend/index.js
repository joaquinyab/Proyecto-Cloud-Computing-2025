// ===== Dependencias =====
const mysql = require('mysql2/promise');
const {
  SNSClient,
  PublishCommand,
  CreateTopicCommand,
  SubscribeCommand,
  ListSubscriptionsByTopicCommand,
  GetSubscriptionAttributesCommand,
  SetSubscriptionAttributesCommand,
  
} = require('@aws-sdk/client-sns');

const sns = new SNSClient({});

// ===== SNS por viaje (con filtros) =====
const TOPIC_PREFIX = process.env.TOPIC_PREFIX || 'tripmate-';

async function getOrCreateTripTopicArn(viajeId) {
  const { nombre, code } = await getTripMetaById(viajeId);
  const slug = slugifyForTopic(nombre);
  const basePrefix = `${TOPIC_PREFIX}${code}-viaje-`;
  const maxSlugLen = 256 - basePrefix.length;
  const safeSlug = slug.slice(0, Math.max(1, maxSlugLen));
  const name = basePrefix + safeSlug;
  const out = await sns.send(new CreateTopicCommand({ Name: name }));
  return out.TopicArn;
}

async function ensureFilteredSubscriptions(viajeId, email) {
  const TopicArn = await getOrCreateTripTopicArn(viajeId);
  const lower = String(email || '').toLowerCase();
  if (!lower) return TopicArn;

  const list = await sns.send(new ListSubscriptionsByTopicCommand({ TopicArn }));
  const subs = (list.Subscriptions || []).filter(
    s => s.Protocol === 'email' && String(s.Endpoint || '').toLowerCase() === lower
  );

  const withAttrs = [];
  for (const s of subs) {
    try {
      const a = await sns.send(new GetSubscriptionAttributesCommand({ SubscriptionArn: s.SubscriptionArn }));
      const fp = a?.Attributes?.FilterPolicy || '';
      withAttrs.push({ ...s, filter: fp });
    } catch {
      withAttrs.push({ ...s, filter: '' });
    }
  }

  const hasBroadcast = withAttrs.some(s => {
    try {
      const fp = JSON.parse(s.filter || '{}');
      return Array.isArray(fp.kind) && fp.kind.includes('broadcast');
    } catch { return false; }
  });

  const hasPersonal = withAttrs.some(s => {
    try {
      const fp = JSON.parse(s.filter || '{}');
      const okKind = Array.isArray(fp.kind) && fp.kind.includes('personal');
      const okUser = Array.isArray(fp.user) &&
                     fp.user.map(x => String(x).toLowerCase()).includes(lower);
      return okKind && okUser;
    } catch { return false; }
  });

  for (const s of withAttrs) {
    if (!s.filter) {
      await sns.send(new SetSubscriptionAttributesCommand({
        SubscriptionArn: s.SubscriptionArn,
        AttributeName: 'FilterPolicy',
        AttributeValue: JSON.stringify({ kind: ['broadcast'] })
      }));
    }
  }

  if (!hasBroadcast) {
    await sns.send(new SubscribeCommand({
      TopicArn,
      Protocol: 'email',
      Endpoint: lower,
      Attributes: {
        FilterPolicy: JSON.stringify({ kind: ['broadcast'] })
      }
    }));
  }

  if (!hasPersonal) {
    await sns.send(new SubscribeCommand({
      TopicArn,
      Protocol: 'email',
      Endpoint: lower,
      Attributes: {
        FilterPolicy: JSON.stringify({ kind: ['personal'], user: [lower] })
      }
    }));
  }

  return TopicArn;
}

async function publishBroadcast(viajeId, subject, message) {
  const TopicArn = await getOrCreateTripTopicArn(viajeId);
  console.log('📨 SNS broadcast → topic:', TopicArn, 'subject:', subject);
  await sns.send(new PublishCommand({
    TopicArn,
    Subject: subject,
    Message: message,
    MessageAttributes: {
      kind: { DataType: 'String', StringValue: 'broadcast' }
    }
  }));
}

async function publishPersonal(viajeId, email, subject, message) {
  const TopicArn = await getOrCreateTripTopicArn(viajeId);
  const lower = String(email || '').toLowerCase();
  if (!lower) return;
  console.log('📨 SNS personal → topic:', TopicArn, 'dest:', lower, 'subject:', subject);
  await sns.send(new PublishCommand({
    TopicArn,
    Subject: subject,
    Message: message,
    MessageAttributes: {
      kind: { DataType: 'String', StringValue: 'personal' },
      user: { DataType: 'String', StringValue: lower }
    }
  }));
}

// ===== Helpers =====
function getEmailFromEvent(event) {
  // API Gateway Authorizer ya validó el token y extrajo los claims
  const claims = event?.requestContext?.authorizer?.claims || {};
  const email = claims.email || claims['cognito:username'] || null;
  return email ? email.toLowerCase() : null;
}
function corsHeaders() {
  const origin = process.env.CORS_ORIGIN || '*';
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Allow-Methods': 'OPTIONS,POST,GET',
  };
}
function send(status, body) { return { statusCode: status, headers: corsHeaders(), body: JSON.stringify(body) }; }
const ok = (b) => send(200, b);
const bad = (b) => send(400, b);
const unauthorized = (b) => send(401, b);
const notfound = (b) => send(404, b);
const fail = (e) => { console.error(e); return send(500, { ok:false, error:String(e?.message||e||'server_error') }); };

// ===== Auto-init + Migración compatible =====
let schemaReady = false;

async function columnExists(conn, dbName, table, column) {
  const [rows] = await conn.query(
    `SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ? LIMIT 1`,
    [dbName, table, column]
  );
  return rows.length > 0;
}

async function ensureSchema() {
  if (schemaReady) return;

  const DB_HOST = process.env.DB_HOST;
  const DB_USER = process.env.DB_USER;
  const DB_PASSWORD = process.env.DB_PASSWORD;
  const DB_NAME = process.env.DB_NAME || 'basededatostripmate2025bd';

  const admin = await mysql.createConnection({ host: DB_HOST, user: DB_USER, password: DB_PASSWORD, multipleStatements:true });
  await admin.query(`CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;`);
  await admin.end();

  const conn = await mysql.createConnection({ 
    host: DB_HOST, 
    user: DB_USER, 
    password: DB_PASSWORD, 
    database: DB_NAME, 
    multipleStatements:true, 
    ssl: { 
        rejectUnauthorized: false 
    }});

  // VIAJES
  await conn.query(`
    CREATE TABLE IF NOT EXISTS viajes (
      id INT AUTO_INCREMENT PRIMARY KEY,
      user_sub VARCHAR(255) NULL,
      user_email VARCHAR(255) NULL,
      nombre VARCHAR(255) NOT NULL,
      access_code VARCHAR(12) NULL,
      fecha_inicio DATE NULL,
      fecha_fin DATE NULL,
      presupuesto_total DECIMAL(10,2) NULL DEFAULT 0,
      alerta_70_enviada TINYINT(1) NOT NULL DEFAULT 0,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE KEY uk_viajes_code (access_code)
    ) ENGINE=InnoDB;
  `);
  if (!(await columnExists(conn, DB_NAME, 'viajes', 'user_email'))) {
    await conn.query(`ALTER TABLE viajes ADD COLUMN user_email VARCHAR(255) NULL;`);
  }
  if (!(await columnExists(conn, DB_NAME, 'viajes', 'access_code'))) {
    await conn.query(`ALTER TABLE viajes ADD COLUMN access_code VARCHAR(12) NULL;`);
    await conn.query(`ALTER TABLE viajes ADD UNIQUE KEY uk_viajes_code (access_code);`);
  } else {
    try { await conn.query(`ALTER TABLE viajes ADD UNIQUE KEY uk_viajes_code (access_code);`); } catch(_) {}
  }
  if (!(await columnExists(conn, DB_NAME, 'viajes', 'fecha_inicio'))) {
    await conn.query(`ALTER TABLE viajes ADD COLUMN fecha_inicio DATE NULL;`);
  }
  if (!(await columnExists(conn, DB_NAME, 'viajes', 'fecha_fin'))) {
    await conn.query(`ALTER TABLE viajes ADD COLUMN fecha_fin DATE NULL;`);
  }
  if (!(await columnExists(conn, DB_NAME, 'viajes', 'presupuesto_total'))) {
    await conn.query(`
      ALTER TABLE viajes
      ADD COLUMN presupuesto_total DECIMAL(10,2) NULL DEFAULT 0 AFTER fecha_fin;
    `);
  }
  if (!(await columnExists(conn, DB_NAME, 'viajes', 'alerta_70_enviada'))) {
    await conn.query(`
      ALTER TABLE viajes
      ADD COLUMN alerta_70_enviada TINYINT(1) NOT NULL DEFAULT 0 AFTER presupuesto_total;
    `);
  }
  try {
    const [cols] = await conn.query(
      `SELECT CHARACTER_MAXIMUM_LENGTH as len
         FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA=? AND TABLE_NAME='viajes' AND COLUMN_NAME='nombre'`,
      [DB_NAME]
    );
    const len = cols?.[0]?.len;
    if (len && Number(len) < 255) await conn.query(`ALTER TABLE viajes MODIFY COLUMN nombre VARCHAR(255) NOT NULL;`);
  } catch {}

  // ACTIVIDADES
  await conn.query(`
    CREATE TABLE IF NOT EXISTS actividades (
      id INT AUTO_INCREMENT PRIMARY KEY,
      viaje_id INT NOT NULL,
      nombre VARCHAR(255) NOT NULL,
      precio DECIMAL(10,2) NOT NULL DEFAULT 0,
      fecha_inicio DATE NULL,
      fecha_fin DATE NULL,
      created_by_email VARCHAR(255) NULL,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT fk_actividades_viaje FOREIGN KEY (viaje_id) REFERENCES viajes(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;
  `);
  if (!(await columnExists(conn, DB_NAME, 'actividades', 'fecha_inicio'))) {
    await conn.query(`ALTER TABLE actividades ADD COLUMN fecha_inicio DATE NULL AFTER precio;`);
  }
  if (!(await columnExists(conn, DB_NAME, 'actividades', 'fecha_fin'))) {
    await conn.query(`ALTER TABLE actividades ADD COLUMN fecha_fin DATE NULL AFTER fecha_inicio;`);
  }

  // VOTOS
  await conn.query(`
    CREATE TABLE IF NOT EXISTS actividad_votos (
      actividad_id INT NOT NULL,
      user_email   VARCHAR(255) NOT NULL,
      voto         TINYINT(1) NOT NULL,
      created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at   TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
      PRIMARY KEY (actividad_id, user_email),
      CONSTRAINT fk_votos_actividad FOREIGN KEY (actividad_id) REFERENCES actividades(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;
  `);

  // MIEMBROS
  await conn.query(`
    CREATE TABLE IF NOT EXISTS viaje_miembros (
      viaje_id   INT NOT NULL,
      user_email VARCHAR(255) NOT NULL,
      joined_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (viaje_id, user_email),
      CONSTRAINT fk_miembros_viaje FOREIGN KEY (viaje_id) REFERENCES viajes(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;
  `);

  // PAGOS DE ACTIVIDADES
  await conn.query(`
    CREATE TABLE IF NOT EXISTS actividad_pagos (
      actividad_id INT NOT NULL,
      user_email   VARCHAR(255) NOT NULL,
      pagado       TINYINT(1) NOT NULL DEFAULT 0,
      fecha_pago   TIMESTAMP NULL DEFAULT NULL,
      created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at   TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
      PRIMARY KEY (actividad_id, user_email),
      CONSTRAINT fk_pagos_actividad FOREIGN KEY (actividad_id) REFERENCES actividades(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;
  `);
  if (!(await columnExists(conn, DB_NAME, 'actividad_pagos', 'pagado'))) {
    await conn.query(`ALTER TABLE actividad_pagos ADD COLUMN pagado TINYINT(1) NOT NULL DEFAULT 0 AFTER user_email;`);
  }
  if (!(await columnExists(conn, DB_NAME, 'actividad_pagos', 'fecha_pago'))) {
    await conn.query(`ALTER TABLE actividad_pagos ADD COLUMN fecha_pago TIMESTAMP NULL DEFAULT NULL AFTER pagado;`);
  }
  if (!(await columnExists(conn, DB_NAME, 'actividad_pagos', 'created_at'))) {
    await conn.query(`ALTER TABLE actividad_pagos ADD COLUMN created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP AFTER fecha_pago;`);
  }
  if (!(await columnExists(conn, DB_NAME, 'actividad_pagos', 'updated_at'))) {
    await conn.query(`ALTER TABLE actividad_pagos ADD COLUMN updated_at TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP AFTER created_at;`);
  }
  try { await conn.query(`ALTER TABLE actividad_pagos ADD PRIMARY KEY (actividad_id, user_email);`); } catch(_) {}
  try {
    await conn.query(`
      ALTER TABLE actividad_pagos
      ADD CONSTRAINT fk_pagos_actividad
      FOREIGN KEY (actividad_id) REFERENCES actividades(id) ON DELETE CASCADE
    `);
  } catch(_) {}

  // CHECKLIST / TODOS DEL VIAJE
  await conn.query(`
    CREATE TABLE IF NOT EXISTS viaje_todos (
      id INT AUTO_INCREMENT PRIMARY KEY,
      viaje_id INT NOT NULL,
      texto VARCHAR(500) NOT NULL,
      done TINYINT(1) NOT NULL DEFAULT 0,
      created_by_email VARCHAR(255) NULL,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
      CONSTRAINT fk_todos_viaje FOREIGN KEY (viaje_id) REFERENCES viajes(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;
  `);

  await conn.query(`UPDATE viajes SET user_email = LOWER(user_email) WHERE user_email IS NOT NULL`);
  await conn.query(`UPDATE viaje_miembros SET user_email = LOWER(user_email)`);
  await conn.query(`UPDATE actividad_pagos SET user_email = LOWER(user_email)`);
  await conn.query(`UPDATE actividad_votos SET user_email = LOWER(user_email)`);

  await conn.end();
  schemaReady = true;
}

async function getConn() {
  return mysql.createConnection({
    host: process.env.DB_HOST,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME || 'basededatostripmate2025bd',
    connectTimeout: 5000,
  });
}

async function getTripMetaById(viajeId) {
  const conn = await getConn();
  try {
    const [[row]] = await conn.query(
      'SELECT nombre, access_code FROM viajes WHERE id = ? LIMIT 1',
      [viajeId]
    );
    if (!row) {
      return {
        nombre: `viaje-${viajeId}`,
        code: `VIAJE-${viajeId}`
      };
    }
    return {
      nombre: String(row.nombre || `viaje-${viajeId}`),
      code: String(row.access_code || `VIAJE-${viajeId}`)
    };
  } finally {
    await conn.end();
  }
}

function slugifyForTopic(nombre) {
  let s = (nombre || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  s = s.replace(/[^A-Za-z0-9-_]+/g, '-');
  s = s.replace(/^-+|-+$/g, '');
  if (!s) s = 'viaje';
  return s;
}

function genCode(n=6){
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let s=''; for (let i=0;i<n;i++) s += chars[Math.floor(Math.random()*chars.length)];
  return s;
}

// ===== Validaciones de fechas =====
function parseDateOnly(s) {
  if (!s) return null;
  try {
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
    const d = new Date(s);
    if (isNaN(d)) return null;
    const y = d.getUTCFullYear();
    const m = String(d.getUTCMonth()+1).padStart(2,'0');
    const day = String(d.getUTCDate()).padStart(2,'0');
    return `${y}-${m}-${day}`;
  } catch { return null; }
}
function dateLE(a,b){ return a<=b; }
function dateGE(a,b){ return a>=b; }
function withinRange(dStart, dEnd, rStart, rEnd) {
  return dateGE(dStart, rStart) && dateLE(dEnd, rEnd);
}

// ===== Job diario: recordatorio 1 día antes =====
async function runDailyPaymentReminders(refDateIso) {
  const conn = await getConn();
  try {
    const base = refDateIso ? new Date(refDateIso) : new Date();

    const utc = new Date(Date.UTC(
      base.getUTCFullYear(),
      base.getUTCMonth(),
      base.getUTCDate()
    ));

    utc.setUTCDate(utc.getUTCDate() + 1);

    const y = utc.getUTCFullYear();
    const m = String(utc.getUTCMonth() + 1).padStart(2, '0');
    const d = String(utc.getUTCDate(), 10).padStart(2, '0');
    const tomorrow = `${y}-${m}-${d}`;

    console.log('⏰ Job diario: buscando actividades con fecha_inicio =', tomorrow);

    const [acts] = await conn.query(
      `SELECT id, viaje_id, nombre, fecha_inicio, precio
         FROM actividades
        WHERE fecha_inicio = ?`,
      [tomorrow]
    );

    if (!acts.length) {
      console.log('⏰ Job diario: no hay actividades para mañana');
      return;
    }

    for (const act of acts) {
      const viajeId = act.viaje_id;

      const [[countMiembros]] = await conn.query(`
        SELECT COUNT(*) AS total_miembros
        FROM (
          SELECT user_email FROM viaje_miembros WHERE viaje_id = ?
          UNION
          SELECT user_email FROM viajes WHERE id = ? AND user_email IS NOT NULL
        ) x
      `, [viajeId, viajeId]);
      const totalMiembros = Math.max(1, countMiembros?.total_miembros || 1);

      const [[pagosStats]] = await conn.query(`
        SELECT SUM(CASE WHEN pagado=1 THEN 1 ELSE 0 END) AS pagados
        FROM actividad_pagos
        WHERE actividad_id=?
      `, [act.id]);

      const pagados = Number(pagosStats?.pagados || 0);
      const per_persona = totalMiembros > 0 ? Number(act.precio || 0) / totalMiembros : Number(act.precio || 0);
      const perPersonaFmt = Number(per_persona || 0).toFixed(2);

      const msg = `
Mañana (${act.fecha_inicio}) es la actividad "${act.nombre}" de tu viaje.

Monto estimado por persona: ${perPersonaFmt}
Pagaron hasta ahora: ${pagados} de ${totalMiembros} personas.

Te recordamos que, si todavía no lo hiciste, marques tu pago en la app TripMate.
`.trim();

      console.log('⏰ Enviando broadcast de recordatorio para actividad id =', act.id);

      await publishBroadcast(
        viajeId,
        'Recordatorio: mañana es tu actividad',
        msg
      );
    }
  } finally {
    await conn.end();
  }
}

// ===== Alerta 70% presupuesto =====
async function checkAndSendBudgetAlert(conn, viajeId) {
  const [[v]] = await conn.query(
    `SELECT presupuesto_total, alerta_70_enviada
       FROM viajes
      WHERE id = ?
      LIMIT 1`,
    [viajeId]
  );
  if (!v) return;

  const presupuesto = Number(v.presupuesto_total || 0);
  if (!Number.isFinite(presupuesto) || presupuesto <= 0) return;

  const [[tot]] = await conn.query(
    `SELECT IFNULL(SUM(precio),0) AS total_actividades
       FROM actividades
      WHERE viaje_id = ?`,
    [viajeId]
  );

  const totalActiv = Number(tot?.total_actividades || 0);
  if (!Number.isFinite(totalActiv)) return;

  const ratio = presupuesto > 0 ? totalActiv / presupuesto : 0;

  if (Number(v.alerta_70_enviada || 0) === 0 && ratio >= 0.7) {
    const porcentaje = Math.round(ratio * 100);
    const { nombre: viajeNombre } = await getTripMetaById(viajeId);

    const msg = `
Alerta de presupuesto en tu viaje "${viajeNombre}"

Las actividades cargadas ya suman aproximadamente el ${porcentaje}% del presupuesto total del viaje.

• Presupuesto total: ${presupuesto.toFixed(2)}
• Suma de actividades: ${totalActiv.toFixed(2)}

Revisen si quieren ajustar el presupuesto o las actividades para no pasarse.
`.trim();

    try {
      await publishBroadcast(
        viajeId,
        `Alerta: 70% del presupuesto alcanzado en "${viajeNombre}"`,
        msg
      );
      await conn.query(
        `UPDATE viajes
            SET alerta_70_enviada = 1
          WHERE id = ?`,
        [viajeId]
      );
      console.log('📊 Enviada alerta 70% presupuesto para viaje', viajeId);
    } catch (e) {
      console.warn('No se pudo enviar alerta 70% presupuesto:', e?.message);
    }
  }
}

// ===== Handler =====
exports.handler = async (event) => {
  try {
    const isScheduled =
      event?.source === 'aws.events' ||
      event?.source === 'aws.events.cloudwatch' ||
      event?.['detail-type'] === 'Scheduled Event';

    if (isScheduled) {
      console.log('⏰ Evento programado recibido:', JSON.stringify(event));

      const refTime = event?.time || null;

      await ensureSchema();
      await runDailyPaymentReminders(refTime);

      return {
        statusCode: 200,
        body: JSON.stringify({ ok: true, job: 'daily_payment_reminders_sent' })
      };
    }

    const method = (event?.requestContext?.http?.method || event?.httpMethod || '').toUpperCase();
    const rawPath = (event?.requestContext?.http?.path || event?.rawPath || event?.path || event?.resource || '');
    const path = rawPath.toLowerCase().replace(/\/+$/,'');

    if (method === 'OPTIONS') return send(200, { ok:true });

    await ensureSchema();

    if (method==='GET' && path.endsWith('/ping')) return ok({ ok:true, time:new Date().toISOString() });
    if (method==='GET' && path.endsWith('/dbcheck')) {
      try {
        const conn = await getConn();
        const [[r]] = await conn.query('SELECT 1 AS ok');
        await conn.end();
        return ok({ ok: r?.ok === 1 });
      } catch (e) { return fail(e); }
    }

    // ----- VIAJES -----
    if (method==='GET' && path.endsWith('/listar')) {
      const email = getEmailFromEvent(event);
      if (!email) return ok([]);

      const conn = await getConn();
      const [rows] = await conn.query(
        `
        SELECT
          v.id,
          v.nombre,
          v.access_code,
          v.fecha_inicio,
          v.fecha_fin,
          v.presupuesto_total,
          COALESCE(v.user_email, v.user_sub) AS owner,
          v.created_at
        FROM viajes v
        LEFT JOIN viaje_miembros m
          ON m.viaje_id = v.id
         AND m.user_email = ?
        WHERE
              v.user_email = ?
           OR v.user_sub   = ?
           OR m.user_email IS NOT NULL
        ORDER BY v.id DESC
        `,
        [email, email, email]
      );
      await conn.end();
      return ok(rows);
    }

    if (method==='POST' && path.endsWith('/guardar')) {
      let body={};
      try { body = typeof event.body === 'string' ? JSON.parse(event.body||'{}') : (event.body||{}); }
      catch { return bad({ ok:false, error:'JSON inválido' }); }

      if (body.delete_viaje) {
        const viajeId = Number(body.delete_viaje);
        if (!Number.isInteger(viajeId) || viajeId <= 0) return bad({ ok:false, error:'viaje id inválido' });

        const email = getEmailFromEvent(event) || null;
        const conn = await getConn();
        const [[v]] = await conn.query(`SELECT id, user_email, user_sub FROM viajes WHERE id=?`, [viajeId]);
        if (!v) { await conn.end(); return notfound({ ok:false, error:'viaje no encontrado' }); }
        if (email && (v.user_email === email || v.user_sub === email)) {
          await conn.query(`DELETE FROM viajes WHERE id=?`, [viajeId]);
          await conn.end();
          return ok({ ok:true, deleted: viajeId });
        } else {
          await conn.end();
          return unauthorized({ ok:false, error:'no sos owner del viaje' });
        }
      }

      const nombre = String(body?.nombre||'').trim();
      const fi = parseDateOnly(body?.fecha_inicio);
      const ff = parseDateOnly(body?.fecha_fin);
      if (!nombre) return bad({ ok:false, error:'nombre requerido' });
      if (!fi || !ff) return bad({ ok:false, error:'fecha_inicio y fecha_fin requeridas (YYYY-MM-DD)' });
      if (!dateLE(fi, ff)) return bad({ ok:false, error:'fecha_inicio debe ser <= fecha_fin' });

      let presupuesto_total = null;
      if (body.hasOwnProperty('presupuesto_total') && body.presupuesto_total !== null && body.presupuesto_total !== '') {
        const num = Number(body.presupuesto_total);
        if (!Number.isFinite(num) || num < 0) {
          return bad({ ok:false, error:'presupuesto_total inválido' });
        }
        presupuesto_total = num;
      }

      const email = getEmailFromEvent(event) || null;

      const conn = await getConn();
      let code;
      for (let i=0; i<6; i++) {
        code = genCode(6);
        try {
          const [r] = await conn.execute(
            `INSERT INTO viajes (nombre, user_email, user_sub, access_code, fecha_inicio, fecha_fin, presupuesto_total)
             VALUES (?,?,?,?,?,?,?)`,
            [nombre, email, email, code, fi, ff, presupuesto_total]
          );
          if (email) {
            await conn.query(`
              INSERT INTO viaje_miembros (viaje_id, user_email)
              VALUES (?, ?)
              ON DUPLICATE KEY UPDATE joined_at = joined_at
            `, [r.insertId, email]);

            try { await ensureFilteredSubscriptions(r.insertId, email); }
            catch (e) { console.warn('ensureFilteredSubscriptions owner failed:', e?.message); }
          }
          await conn.end();

          const legacyTopic = process.env.SNS_TOPIC || process.env.SNSTOPIC;
          if (legacyTopic) {
            try {
              await sns.send(new PublishCommand({ TopicArn: legacyTopic, Message: `Nuevo viaje: ${nombre} (${fi} → ${ff})` }));
            } catch(e){ console.warn('SNS publish failed:', e?.message); }
          }
          return ok({
            ok:true,
            id:r.insertId,
            access_code: code,
            fecha_inicio: fi,
            fecha_fin: ff,
            presupuesto_total: presupuesto_total ?? 0
          });
        } catch (e) {
          if (!String(e?.message||'').includes('Duplicate')) return fail(e);
        }
      }
      return fail(new Error('No se pudo generar código único'));
    }

    // ----- UNIRSE A VIAJE -----
    if (method==='POST' && path.endsWith('/unirse')) {
      let body={};
      try { body = typeof event.body === 'string' ? JSON.parse(event.body||'{}') : (event.body||{}); }
      catch { return bad({ ok:false, error:'JSON inválido' }); }

      const codigo = String(body?.codigo||'').trim().toUpperCase();
      if (!codigo) return bad({ ok:false, error:'codigo requerido' });

      const email = getEmailFromEvent(event);
      if (!email) return unauthorized({ ok:false, error:'login requerido para unirse' });

      const conn = await getConn();
      const [[viaje]] = await conn.query(`SELECT id, nombre FROM viajes WHERE access_code = ?`, [codigo]);
      if (!viaje) { await conn.end(); return notfound({ ok:false, error:'codigo inválido' }); }

      await conn.query(`
        INSERT INTO viaje_miembros (viaje_id, user_email)
        VALUES (?, ?)
        ON DUPLICATE KEY UPDATE joined_at = joined_at
      `, [viaje.id, email]);
      await conn.end();

      try { await ensureFilteredSubscriptions(viaje.id, email); }
      catch (e) { console.warn('ensureFilteredSubscriptions member failed:', e?.message); }

      return ok({ ok:true, viaje_id: viaje.id, nombre: viaje.nombre });
    }

    // ===== RESUMEN POR PERSONA =====
    const mResumen = path.match(/\/viajes\/(\d+)\/resumen$/);
    if (mResumen && method === 'GET') {
      const viajeId = parseInt(mResumen[1], 10);
      const conn = await getConn();

      try {
        const [miembrosRows] = await conn.query(`
          SELECT LOWER(user_email) AS user_email
          FROM (
            SELECT user_email FROM viaje_miembros WHERE viaje_id = ?
            UNION
            SELECT user_email FROM viajes WHERE id = ? AND user_email IS NOT NULL
          ) m
          WHERE user_email IS NOT NULL
          ORDER BY user_email
        `, [viajeId, viajeId]);

        const miembros = miembrosRows
          .map(r => String(r.user_email || '').toLowerCase())
          .filter(x => x);

        if (!miembros.length) {
          await conn.end();
          return ok({ ok: true, resumen: [] });
        }

        const numMiembros = miembros.length;

        const [acts] = await conn.query(`
          SELECT id, precio
          FROM actividades
          WHERE viaje_id = ?
        `, [viajeId]);

        if (!acts.length) {
          await conn.end();
          return ok({ ok: true, resumen: [] });
        }

        const shareByAct = {};
        let totalPorPersona = 0;

        for (const a of acts) {
          const precio = Number(a.precio || 0);
          const share = numMiembros > 0 ? (precio / numMiembros) : 0;
          const share2 = Number(share.toFixed(2));
          shareByAct[a.id] = share2;
          totalPorPersona += share2;
        }
        totalPorPersona = Number(totalPorPersona.toFixed(2));

        const [pagosRows] = await conn.query(`
          SELECT actividad_id, LOWER(user_email) AS user_email, pagado
          FROM actividad_pagos
          WHERE actividad_id IN (SELECT id FROM actividades WHERE viaje_id = ?)
        `, [viajeId]);

        const pagadoPorPersona = {};
        for (const p of pagosRows) {
          if (Number(p.pagado) !== 1) continue;
          const email = String(p.user_email || '').toLowerCase();
          const share = shareByAct[p.actividad_id] || 0;
          pagadoPorPersona[email] = Number(
            ((pagadoPorPersona[email] || 0) + share).toFixed(2)
          );
        }

        const resumen = miembros.map(email => {
          const debe = totalPorPersona;
          const pago = pagadoPorPersona[email] || 0;
          const saldo = Number((debe - pago).toFixed(2));
          return { user_email: email, debe, pago, saldo };
        });

        await conn.end();
        return ok({ ok: true, resumen });
      } catch (e) {
        await conn.end();
        throw e;
      }
    }

    // ===== TODOS (CHECKLIST DEL VIAJE) =====
    const mTodos = path.match(/\/viajes\/(\d+)\/todos$/);
    if (mTodos) {
      const viajeId = parseInt(mTodos[1], 10);

      if (method === 'GET') {
        const conn = await getConn();
        const [rows] = await conn.query(
          `SELECT id, viaje_id, texto AS text, done, created_by_email, created_at, updated_at
             FROM viaje_todos
            WHERE viaje_id = ?
            ORDER BY created_at ASC, id ASC`,
          [viajeId]
        );
        await conn.end();
        return ok({ ok:true, todos: rows });
      }

      if (method === 'POST') {
        let body={};
        try { body = typeof event.body === 'string' ? JSON.parse(event.body||'{}') : (event.body||{}); }
        catch { return bad({ ok:false, error:'JSON inválido' }); }

        const email = getEmailFromEvent(event) || null;
        const conn = await getConn();

        try {
          if (body.delete_id) {
            const todoId = Number(body.delete_id);
            if (!Number.isInteger(todoId) || todoId <= 0) {
              await conn.end();
              return bad({ ok:false, error:'todo id inválido' });
            }
            await conn.execute(
              `DELETE FROM viaje_todos WHERE id=? AND viaje_id=?`,
              [todoId, viajeId]
            );
            await conn.end();
            return ok({ ok:true, deleted: todoId });
          }

          if (body.toggle_id !== undefined && body.toggle_id !== null) {
            const todoId = Number(body.toggle_id);
            if (!Number.isInteger(todoId) || todoId <= 0) {
              await conn.end();
              return bad({ ok:false, error:'todo id inválido' });
            }
            const doneVal = Number(body.done) === 1 ? 1 : 0;
            await conn.execute(
              `UPDATE viaje_todos SET done=? WHERE id=? AND viaje_id=?`,
              [doneVal, todoId, viajeId]
            );
            await conn.end();
            return ok({ ok:true, id: todoId, done: doneVal });
          }

          const texto = String(body.text || '').trim();
          if (!texto) {
            await conn.end();
            return bad({ ok:false, error:'text requerido' });
          }

          const [r] = await conn.execute(
            `INSERT INTO viaje_todos (viaje_id, texto, done, created_by_email)
             VALUES (?,?,0,?)`,
            [viajeId, texto, email]
          );
          await conn.end();
          return ok({ ok:true, id: r.insertId });
        } catch (e) {
          await conn.end();
          throw e;
        }
      }
    }

    // ----- ACTIVIDADES -----
    const mAct = path.match(/\/viajes\/(\d+)\/actividades$/);
    if (mAct) {
      const viajeId = parseInt(mAct[1], 10);
      const conn = await getConn();

      if (method==='GET') {
        const currentEmail = getEmailFromEvent(event) || '';

        const [[countResult]] = await conn.query(`
          SELECT COUNT(*) AS total_miembros
          FROM (
            SELECT user_email FROM viaje_miembros WHERE viaje_id = ?
            UNION
            SELECT user_email FROM viajes WHERE id = ? AND user_email IS NOT NULL
          ) x
        `, [viajeId, viajeId]);
        const totalMiembros = Math.max(1, countResult?.total_miembros || 1);

        const [[tripRow]] = await conn.query(
          `SELECT presupuesto_total FROM viajes WHERE id = ? LIMIT 1`,
          [viajeId]
        );
        const presupuestoTotal = Number(tripRow?.presupuesto_total || 0);

        const [rows] = await conn.query(`
          SELECT
            a.id,
            a.viaje_id,
            a.nombre,
            a.precio,
            a.created_by_email,
            a.created_at,
            a.fecha_inicio,
            a.fecha_fin,
            IFNULL(SUM(CASE WHEN v.voto=1 THEN 1 ELSE 0 END),0) AS votos_favor,
            IFNULL(SUM(CASE WHEN v.voto=0 THEN 1 ELSE 0 END),0) AS votos_contra,
            COUNT(v.user_email) AS total_votos,
            IFNULL(MAX(apu.pagado), 0) AS yo_pagado
          FROM actividades a
          LEFT JOIN actividad_votos v
            ON v.actividad_id = a.id
          LEFT JOIN actividad_pagos apu
            ON apu.actividad_id = a.id
           AND apu.user_email   = ?
          WHERE a.viaje_id = ?
          GROUP BY
            a.id, a.viaje_id, a.nombre, a.precio, a.created_by_email,
            a.created_at, a.fecha_inicio, a.fecha_fin
          ORDER BY a.created_at DESC, a.id DESC
        `, [currentEmail, viajeId]);

        const [voters] = await conn.query(`
          SELECT actividad_id, user_email, voto, updated_at, created_at
          FROM actividad_votos
          WHERE actividad_id IN (SELECT id FROM actividades WHERE viaje_id = ?)
        `, [viajeId]);

        const [pagos] = await conn.query(`
          SELECT actividad_id, user_email, pagado, fecha_pago
          FROM actividad_pagos
          WHERE actividad_id IN (SELECT id FROM actividades WHERE viaje_id = ?)
        `, [viajeId]);

        const pagosByAct = pagos.reduce((m,p)=>{ (m[p.actividad_id] ??= []).push(p); return m; }, {});
        const actividades = rows.map(a => {
          const lista = pagosByAct[a.id] || [];
          const pagados = lista.filter(p => Number(p.pagado) === 1).length;
          const per_persona = totalMiembros > 0 ? Number(a.precio || 0) / totalMiembros : Number(a.precio || 0);
          const total_pagado = pagados * per_persona;
          const restante = Math.max(0, Number((Number(a.precio || 0) - total_pagado).toFixed(2)));
          const porcentaje_pagado = Number(a.precio || 0) > 0
            ? Math.min(100, Math.max(0, (total_pagado / Number(a.precio)) * 100))
            : 0;

          return {
            ...a,
            per_persona: Number(per_persona.toFixed(2)),
            pagados,
            restante,
            porcentaje_pagado: Number(porcentaje_pagado.toFixed(2)),
            yo_pagado: Number(a.yo_pagado) === 1
          };
        });

        const totalActividades = actividades.reduce(
          (s, a) => s + Number(a.precio || 0),
          0
        );

        await conn.end();
        return ok({
          actividades,
          votos: voters,
          pagos,
          total_miembros: totalMiembros,
          presupuesto_total: presupuestoTotal,
          total_actividades: totalActividades
        });
      }

      if (method==='POST') {
        let body={}; 
        try{ body = typeof event.body === 'string' ? JSON.parse(event.body||'{}') : (event.body||{}); }
        catch { await conn.end(); return bad({ ok:false, error:'JSON inválido' }); }

        if (body.delete_id) {
          const actId = Number(body.delete_id);
          if (!Number.isInteger(actId) || actId <= 0) { await conn.end(); return bad({ ok:false, error:'actividad id inválido' }); }
          await conn.execute(`DELETE FROM actividades WHERE id=? AND viaje_id=?`, [actId, viajeId]);
          await conn.end();
          return ok({ ok:true, deleted: actId });
        }

        const nombre = String(body?.nombre||'').trim();
        const precio = Number(body?.precio||0);
        const fi = parseDateOnly(body?.fecha_inicio);
        const ff = parseDateOnly(body?.fecha_fin);

        if (!nombre) { await conn.end(); return bad({ ok:false, error:'nombre requerido' }); }
        if (!(Number.isFinite(precio) && precio >= 0)) { await conn.end(); return bad({ ok:false, error:'precio inválido' }); }
        if (!fi || !ff) { await conn.end(); return bad({ ok:false, error:'fecha_inicio y fecha_fin de actividad requeridas (YYYY-MM-DD)' }); }
        if (!dateLE(fi, ff)) { await conn.end(); return bad({ ok:false, error:'fecha_inicio de actividad debe ser <= fecha_fin' }); }

        const [[v]] = await conn.query(`SELECT fecha_inicio, fecha_fin FROM viajes WHERE id=?`, [viajeId]);
        if (!v || !v.fecha_inicio || !v.fecha_fin) { await conn.end(); return bad({ ok:false, error:'el viaje no tiene fechas definidas' }); }
        const tripStart = parseDateOnly(v.fecha_inicio);
        const tripEnd   = parseDateOnly(v.fecha_fin);
        if (!withinRange(fi, ff, tripStart, tripEnd)) { await conn.end(); return bad({ ok:false, error:`la actividad debe estar entre ${tripStart} y ${tripEnd}` }); }

        const email = getEmailFromEvent(event) || null;
        const [r] = await conn.execute(
          `INSERT INTO actividades (viaje_id, nombre, precio, fecha_inicio, fecha_fin, created_by_email)
           VALUES (?,?,?,?,?,?)`,
          [viajeId, nombre, precio, fi, ff, email]
        );

        try {
          await checkAndSendBudgetAlert(conn, viajeId);
        } catch (e) {
          console.warn('checkAndSendBudgetAlert failed:', e?.message);
        }

        try {
          const { nombre: viajeNombre } = await getTripMetaById(viajeId);

          await publishBroadcast(
            viajeId,
            `Nueva actividad en "${viajeNombre}"`,
`Se creó una nueva actividad en tu viaje "${viajeNombre}":
- ${nombre} (${fi} → ${ff})
- Precio: ${precio}
- Creado por: ${email || 'anónimo'}`
          );
        } catch (e) { console.warn('publishBroadcast (actividad) failed:', e?.message); }

        await conn.end();
        return ok({ ok:true, id:r.insertId });
      }
    }

    // ----- VOTAR -----
    const mVote = path.match(/\/viajes\/(\d+)\/actividades\/(\d+)\/votar$/);
    if (mVote && method==='POST') {
      const viajeId = parseInt(mVote[1], 10);
      const actId = parseInt(mVote[2], 10);
      let body={}; try{ body = typeof event.body === 'string' ? JSON.parse(event.body||'{}') : (event.body||{}); }
      catch { return bad({ ok:false, error:'JSON inválido' }); }

      const voto = Number(body?.voto);
      if (!(voto===0 || voto===1)) return bad({ ok:false, error:'voto debe ser 1 o 0' });
      const email = getEmailFromEvent(event) || 'anon';

      const conn = await getConn();

      const [[act]] = await conn.execute(`SELECT id, viaje_id, nombre FROM actividades WHERE id=?`, [actId]);
      if (!act) { await conn.end(); return notfound({ ok:false, error:'actividad no encontrada' }); }

      await conn.execute(`
        INSERT INTO actividad_votos (actividad_id, user_email, voto)
        VALUES (?,?,?)
        ON DUPLICATE KEY UPDATE voto=VALUES(voto), updated_at=CURRENT_TIMESTAMP
      `, [actId, email, voto]);

      const [[c]] = await conn.query(`
        SELECT
          IFNULL(SUM(CASE WHEN voto=1 THEN 1 ELSE 0 END),0) AS votos_favor,
          IFNULL(SUM(CASE WHEN voto=0 THEN 1 ELSE 0 END),0) AS votos_contra,
          COUNT(*) AS total_votos
        FROM actividad_votos
        WHERE actividad_id=?
      `, [actId]);

      await conn.end();

      try {
        const { nombre: viajeNombre } = await getTripMetaById(act.viaje_id);

        await publishBroadcast(
          act.viaje_id,
          `Nuevo voto en "${viajeNombre}"`,
`Hay un nuevo voto en una actividad de tu viaje "${viajeNombre}":
- Actividad: ${act.nombre}
- Resultado actual: 👍=${c.votos_favor} / 👎=${c.votos_contra}`
        );
      } catch (e) { console.warn('publishBroadcast (voto) failed:', e?.message); }

      return ok({ ok:true, actividad_id: actId, ...c });
    }

    // ===== MARCAR PAGO =====
    const mPago = path.match(/\/viajes\/(\d+)\/actividades\/(\d+)\/pagar$/);
    if (mPago && method==='POST') {
      const viajeId = parseInt(mPago[1], 10);
      const actId = parseInt(mPago[2], 10);
      const email = getEmailFromEvent(event);
      
      console.log('🔍 PAGAR - email extraído:', email);
      
      if (!email) return unauthorized({ ok:false, error:'login requerido' });

      const conn = await getConn();

      const [[act]] = await conn.execute(
        `SELECT id, viaje_id, nombre, precio FROM actividades WHERE id=?`,
        [actId]
      );
      if (!act) { 
        await conn.end(); 
        return notfound({ ok:false, error:'actividad no encontrada' }); 
      }
      
      console.log('🔍 PAGAR - actividad encontrada:', act);

      await conn.query(`
        INSERT INTO viaje_miembros (viaje_id, user_email)
        VALUES (?, ?)
        ON DUPLICATE KEY UPDATE joined_at = joined_at
      `, [viajeId, email]);

      try {
        await ensureFilteredSubscriptions(viajeId, email);
      } catch (e) {
        console.warn('ensureFilteredSubscriptions (payer) failed:', e?.message);
      }
      
      console.log('🔍 PAGAR - miembro asegurado y subs SNS chequeadas');

      const [insertResult] = await conn.execute(`
        INSERT INTO actividad_pagos (actividad_id, user_email, pagado, fecha_pago)
        VALUES (?, ?, 1, CURRENT_TIMESTAMP)
        ON DUPLICATE KEY UPDATE pagado=1, fecha_pago=CURRENT_TIMESTAMP, updated_at=CURRENT_TIMESTAMP
      `, [actId, email]);
      
      console.log('🔍 PAGAR - resultado del INSERT:', {
        affectedRows: insertResult.affectedRows,
        insertId: insertResult.insertId,
        warningStatus: insertResult.warningStatus
      });

      const [[check]] = await conn.query(
        `SELECT actividad_id, user_email, pagado, fecha_pago, created_at, updated_at
          FROM actividad_pagos
          WHERE actividad_id=? AND user_email=?`,
        [actId, email]
      );
      
      console.log('🔍 PAGAR - verificación post-insert:', check);
      
      if (!check || Number(check.pagado) !== 1) {
        console.error('❌ ERROR: El pago NO se guardó en la base de datos');
        await conn.end();
        return send(500, { ok: false, error: 'El pago no se guardó correctamente' });
      }

      const [[countMiembros]] = await conn.query(`
        SELECT COUNT(*) AS total_miembros
        FROM (
          SELECT user_email FROM viaje_miembros WHERE viaje_id = ?
          UNION
          SELECT user_email FROM viajes WHERE id = ? AND user_email IS NOT NULL
        ) x
      `, [viajeId, viajeId]);
      const totalMiembros = Math.max(1, countMiembros?.total_miembros || 1);

      const [[pagosStats]] = await conn.query(`
        SELECT SUM(CASE WHEN pagado=1 THEN 1 ELSE 0 END) AS pagados
        FROM actividad_pagos
        WHERE actividad_id=?
      `, [actId]);

      const pagados = Number(pagosStats?.pagados || 0);
      const per_persona = totalMiembros > 0 ? Number(act.precio || 0) / totalMiembros : Number(act.precio || 0);
      const total_pagado = pagados * per_persona;
      const restante = Math.max(0, Number((Number(act.precio || 0) - total_pagado).toFixed(2)));
      const porcentaje_pagado = Number(act.precio || 0) > 0
        ? Math.min(100, Math.max(0, (total_pagado / Number(act.precio)) * 100))
        : 0;

      console.log('🔢 PAGAR - métricas:', {
        totalMiembros,
        pagados,
        per_persona,
        total_pagado,
        restante,
        porcentaje_pagado
      });

      try {
        const perPersonaFmt = Number(per_persona || 0).toFixed(2);
        const { nombre: viajeNombre } = await getTripMetaById(viajeId);

        const msgBroadcast = `
${email} acaba de marcar su pago en la actividad "${act.nombre}" del viaje "${viajeNombre}".

Monto por persona estimado: ${perPersonaFmt}
Pagaron hasta ahora: ${pagados} de ${totalMiembros} personas.
`.trim();

        await publishBroadcast(
          act.viaje_id,
          `Nuevo pago registrado en el viaje "${viajeNombre}"`,
          msgBroadcast
        );

        const [miembrosRows] = await conn.query(`
          SELECT LOWER(user_email) AS user_email
          FROM (
            SELECT user_email FROM viaje_miembros WHERE viaje_id = ?
            UNION
            SELECT user_email FROM viajes WHERE id = ? AND user_email IS NOT NULL
          ) m
          WHERE user_email IS NOT NULL
        `, [viajeId, viajeId]);

        const [pagaronRows] = await conn.query(`
          SELECT LOWER(user_email) AS user_email
          FROM actividad_pagos
          WHERE actividad_id = ? AND pagado = 1
        `, [actId]);

        const paidSet = new Set(pagaronRows.map(r => r.user_email));

        console.log('🔔 PAGAR - miembros:', miembrosRows);
        console.log('🔔 PAGAR - pagaronRows:', pagaronRows);

        for (const row of miembrosRows) {
          const dest = row.user_email;
          if (!dest) continue;

          try {
            await ensureFilteredSubscriptions(act.viaje_id, dest);

            if (dest === email.toLowerCase()) {
              const subject = `Confirmación de tu pago en el viaje "${viajeNombre}"`;
              const msg = `
Hola ${dest},

Registramos correctamente tu pago en la actividad "${act.nombre}" del viaje "${viajeNombre}".

Monto estimado por persona: ${perPersonaFmt}

¡Gracias por ponerte al día!
`.trim();

              console.log('📧 Enviando mail de confirmación de pago a:', dest);

              await publishPersonal(
                act.viaje_id,
                dest,
                subject,
                msg
              );
              continue;
            }

            if (!paidSet.has(dest)) {
              const subject = `Recordatorio: pago pendiente en el viaje "${viajeNombre}"`;
              const msg = `
Hola ${dest},

${email} ya pagó su parte de la actividad "${act.nombre}" del viaje "${viajeNombre}".

Te recordamos que vos todavía tenés pendiente tu pago en esta actividad.

Monto estimado por persona: ${perPersonaFmt}
Cuando marques tu pago, vas a dejar de recibir estos recordatorios.
`.trim();

              console.log('📧 Enviando recordatorio personal a:', dest);

              await publishPersonal(
                act.viaje_id,
                dest,
                subject,
                msg
              );
            }

          } catch (e) {
            console.warn('publishPersonal (notificación pago) failed:', dest, e?.message);
          }
        }
      } catch (e) {
        console.warn('SNS (pago + notificaciones) failed:', e?.message);
      }

      await conn.end();

      console.log('✅ PAGAR - respuesta final:', {
        ok: true,
        actividad_id: actId,
        user_email: email,
        pagado: true,
        pagados,
        per_persona,
        restante,
        porcentaje_pagado
      });

      return ok({
        ok:true,
        actividad_id: actId,
        per_persona: Number(per_persona.toFixed(2)),
        pagados,
        restante,
        porcentaje_pagado: Number(porcentaje_pagado.toFixed(2)),
        total_miembros: totalMiembros,
        precio: Number(act.precio || 0)
      });
    }

    return notfound({ ok:false, error:'Ruta no encontrada' });

  } catch (e) {
    return fail(e);
  }
};
