const mysql = require('mysql2/promise');

exports.handler = async () => {
  try {
    const DB_HOST = process.env.DB_HOST;
    const DB_USER = process.env.DB_USER || 'admin';
    const DB_PASSWORD = process.env.DB_PASSWORD;
    const DB_NAME = process.env.DB_NAME || 'basededatostripmate2025bd';

    // Crear DB
    const admin = await mysql.createConnection({
      host: DB_HOST, user: DB_USER, password: DB_PASSWORD, multipleStatements: true
    });
    await admin.query(
      `CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
       CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;`
    );
    await admin.end();

    // Conexión a la DB
    const conn = await mysql.createConnection({
      host: DB_HOST,
      user: DB_USER,
      password: DB_PASSWORD,
      database: DB_NAME,
      multipleStatements: true,
      ssl:{ rejectUnauthorized: false }
    });

    // === VIAJES (con fechas, código, presupuesto y flag de alerta) ===
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

    // === ACTIVIDADES (con fechas) ===
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
        CONSTRAINT fk_actividades_viaje
          FOREIGN KEY (viaje_id) REFERENCES viajes(id) ON DELETE CASCADE
      ) ENGINE=InnoDB;
    `);

    // === VOTOS ===
    await conn.query(`
      CREATE TABLE IF NOT EXISTS actividad_votos (
        actividad_id INT NOT NULL,
        user_email   VARCHAR(255) NOT NULL,
        voto         TINYINT(1) NOT NULL,
        created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at   TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (actividad_id, user_email),
        CONSTRAINT fk_votos_actividad
          FOREIGN KEY (actividad_id) REFERENCES actividades(id) ON DELETE CASCADE
      ) ENGINE=InnoDB;
    `);

    // === MIEMBROS DE VIAJE ===
    await conn.query(`
      CREATE TABLE IF NOT EXISTS viaje_miembros (
        viaje_id   INT NOT NULL,
        user_email VARCHAR(255) NOT NULL,
        joined_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (viaje_id, user_email),
        CONSTRAINT fk_miembros_viaje
          FOREIGN KEY (viaje_id) REFERENCES viajes(id) ON DELETE CASCADE
      ) ENGINE=InnoDB;
    `);

    // === PAGOS DE ACTIVIDADES (incluye fecha_pago) ===
    await conn.query(`
      CREATE TABLE IF NOT EXISTS actividad_pagos (
        actividad_id INT NOT NULL,
        user_email   VARCHAR(255) NOT NULL,
        pagado       TINYINT(1) NOT NULL DEFAULT 0,
        fecha_pago   TIMESTAMP NULL DEFAULT NULL,
        created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at   TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (actividad_id, user_email),
        CONSTRAINT fk_pagos_actividad
          FOREIGN KEY (actividad_id) REFERENCES actividades(id) ON DELETE CASCADE
      ) ENGINE=InnoDB;
    `);

    // Normalización idempotente (por si hay datos viejos en mayúsculas)
    await conn.query(`UPDATE viajes SET user_email = LOWER(user_email) WHERE user_email IS NOT NULL`);
    await conn.query(`UPDATE viaje_miembros SET user_email = LOWER(user_email)`);
    await conn.query(`UPDATE actividad_pagos SET user_email = LOWER(user_email)`);
    await conn.query(`UPDATE actividad_votos SET user_email = LOWER(user_email)`);

    await conn.end();
    return { ok: true, msg: 'Base y tablas listas ✅' };
  } catch (e) {
    console.error("ERROR CRITICO EN DBINIT:", e);
    // 👇 ESTO ES CLAVE: Lanzar el error hace que la Lambda falle (Status Failed)
    throw new Error(`DB Init Failed: ${e.message}`);
  }
};
