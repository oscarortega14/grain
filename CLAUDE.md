# Grain — contexto del proyecto

Gema Ruby: **agregados pre-calculados y mantenidos incrementalmente dentro del Postgres de la
propia aplicación**, para que los dashboards de Rails respondan en milisegundos. Publicada como
`grain` 0.0.1 en RubyGems. El repo remoto (`github.com/grainrb/grain`) todavía no existe.

Documentos hermanos: `../proyecto-grain.md` (plan de negocio, modelo open core, criterios para
matar el proyecto), `../ideas-negocio.md`, `../ekklesia/CLAUDE.md` (integración en curso).

## Estado

- **208 tests, 0 fallas. Rubocop limpio.** `bundle exec rake` corre ambos.
- Alcance de la v1 **completo**: definición, esquema, generadores, triggers, worker, `verify`,
  backfill, API de lectura, `DrainJob`.
- **Probada en una app real** (`../golbet`, porras de fútbol): coincide con la implementación de
  referencia en Ruby y lee entre 6x y 62x más rápido.
- **Segunda app, completa** (`../ekklesia`, multi-tenant de verdad con `acts_as_tenant`): dos
  rollups, `verify` limpio, 26 specs que los comparan contra los endpoints que reemplazan, el
  worker programado con Solid Queue (probado en Linux: el drenado ocurre solo) y los tres endpoints
  de `stats` ya leyendo el rollup. Salieron tres cambios de ahí: las lecturas exigen tenant
  (incompatible), la dimensión de tiempo nulable, y los filtros de lista con `nil` o vacíos.
  Detalle en `../ekklesia/CLAUDE.md`.
- **Hay cambios sin commitear** en grain y en golbet (DrainJob, Installer, README). Los commits
  los hace el usuario; yo redacto los mensajes y no ejecuto `git commit`.
- **0.0.2 lista para publicar, sin publicar.** Versión bumpeada, CHANGELOG escrito con sección de
  Upgrading, descripción del gemspec corregida, bloque de estado del README al día, y
  `grain-0.0.2.gem` construida. Falta `git push` y `gem push`, que los hace el usuario.

## Cómo trabajar aquí

```bash
docker run -d --name grain-pg -e POSTGRES_PASSWORD=grain \
  -e POSTGRES_DB=grain_test -p 5433:5432 postgres:18
bundle exec rake          # tests + rubocop
```

Los tests de integración se saltan solos si no hay Postgres. `GRAIN_TEST_DATABASE_URL` lo
reapunta. Los tests corren los generadores de verdad, cargan los archivos que escriben y los
aplican a la base viva: **afirmar sobre strings generados es confianza falsa**, y ya pasó tres
veces que un string perfecto era semánticamente incorrecto.

## La API

```ruby
class OrderRevenueRollup < Grain::Rollup
  fact LineItem, where: { order: { state: "paid" } }

  tenant    :store_id,    via: { order: :store_id }        # obligatorio
  time      :ordered_on,  via: { order: :placed_on }, grain: :day   # opcional
  dimension :product_id,  via: :product_id                  # columna local
  dimension :category_id, via: { product: :category_id }    # un salto
  dimension :currency,    via: { order: :currency }, immutable: true

  measure :line_count,    count: true
  measure :revenue_cents, sum: "quantity * unit_price_cents", type: :bigint
  measure :paid_lines,    sum: "CASE WHEN g_order.state = 'paid' THEN 1 ELSE 0 END",
                          type: :bigint, through: :order
  ratio   :average_unit_price, of: :revenue_cents, over: :line_count
end
```

Generadores: `grain:install` (una vez), `grain:rollup NAME` (esqueleto), `grain:table NAME`
(migración de tabla + triggers; **regenerar cada vez que cambia la definición**).
Tareas: `grain:drain`, `grain:verify` (sale con código != 0), `grain:backfill ROLLUP=`,
`grain:triggers`.
API: `Rollup.for(...).between(...).by(...)`, `.verify(repair:)`, `.backfill(from:, pause:)`,
`Grain::Worker.drain`, `Grain::DrainJob`, `Grain::Installer.install!`.

## Decisiones tomadas — no relitigar

1. **Recomputar una celda es la primitiva; los deltas son la optimización, y la v1 no los tiene.**
   El worker trabaja por lotes, así que 1000 inserts en 10 celdas son 10 recomputaciones.
2. **La regla que gobierna todo**: recomputar una celda que no hacía falta es inofensivo; no
   recomputar una que sí, es el único bug imperdonable. Ante la duda, recomputa.
3. **Recomputar es DELETE + INSERT, no upsert.** Una celda puede quedar legítimamente vacía y un
   upsert dejaría los números viejos para siempre.
4. **Solo cadenas `belongs_to`, máximo 3 saltos.** Es aritmética: por `belongs_to` cada fila de
   hecho cae en exactamente una celda. Cruzar un `has_many` duplicaría cada conteo.
5. **`tenant` obligatorio, `time` opcional.** Sin `time` el rollup es un counter cache verificable.
6. **`sum`/`min`/`max` exigen `type:` explícito.** Adivinar redondearía la plata de alguien.
7. **Un trigger por tabla fuente, nunca por rollup**, y la lista de columnas es la **unión** entre
   todos los rollups que la vigilan.
8. **Las tablas de hechos y las que leen las medidas registran todos los updates** (SQL arbitrario,
   no se sabe qué columnas lo alimentan). Las demás se reducen con precisión.
9. **Alias `f` para el hecho, `g_<camino>` para los joins.** Por el camino completo, no el último
   salto: dos rutas pueden terminar en la misma tabla.
10. **Los ratios se guardan en dos partes y se dividen al leer.** Nunca pre-divididos.
11. **Grain emite archivos de migración**, no crea tablas en runtime, y la migración es una
    fotografía (el SQL va literal, no leído de la gema).
12. **Las lecturas exigen el tenant; cruzarlo se pide por su nombre** (`across_tenants`). Una
    lectura sin tenant no devuelve un número equivocado, devuelve el de otro inquilino, y no hay
    default seguro que Grain pueda elegir: no sabe de quién es el dato que le toca a quien
    pregunta. Un tenant `nil` se rechaza igual, porque ninguna celda puede tener uno y la lectura
    volvería como un cero limpio. La escotilla existe porque el caso legítimo existe (un panel de
    administración), y así queda greppable.
13. **Los agregados se castean al tipo declarado.** `SUM` sobre `bigint` da `numeric`; sin el cast
    hay falsos positivos permanentes en `verify` y `BigDecimal` en las lecturas.

## Patrones de bug que ya morderon — no reintroducir

- **`schema.rb` no representa funciones ni triggers.** Cargar el esquema (así se construyen las
  bases de test, y así funciona `db:reset`) crea las tablas y borra todo lo que las mantiene
  correctas. Sin señal alguna. Se arregla con `Grain::Installer.install!`.
- **Los tests que leen un rollup tienen que drenar.** Incluido uno que muta datos después de que
  su propio setup ya drenó.
- **ActiveRecord reporta `bigint` como `:integer` con `limit: 8`.** Tomarlo literal da llaves de
  4 bytes contra fuentes de 8.
- **`create_table primary_key: [...]` junto con `id: false`** no crea llave primaria alguna, en
  silencio.
- **`Array({a: :b})`** convierte el hash en pares.
- **Enseñarle a los triggers a vigilar una tabla sin enseñárselo al `Registry`**: el trigger
  dispara, el log se llena, el worker la ignora.
- **`FULL OUTER JOIN` en Postgres no acepta `IS NOT DISTINCT FROM`.** `verify` usa `UNION ALL` +
  `GROUP BY`, que además ya trata los nulos como iguales.
- **Afirmar sobre números sin afirmar el tipo.** `assert_equal 1400, BigDecimal(1400)` pasa.
- **`[nil].any?` es `false`, y `[false].any?` también.** Preguntar por verdadez si una lista de
  valores trae algo tira justo los valores que hay que tratar. Va con `empty?`. Recién mordió al
  arreglar los filtros de lista: el `IS NULL` no se agregaba nunca y el `nil` de la lista
  desaparecía en silencio, que es el bug que se estaba arreglando.
- **`IN` trata al nulo como desconocido, no como coordenada.** `for(dim: [id, nil])` dejaba fuera
  las celdas sin valor —las que un panel muestra como "sin categoría"— sin señal. Y `IN ()` no es
  SQL válido: una lista vacía es `FALSE`, no un error de sintaxis.
- **Tratar una dimensión de tiempo como exenta de la nulabilidad de su fuente.** Guarda un bucket,
  no el timestamp, pero el bucket de un nulo es nulo. Declararlo `NOT NULL` dentro de la llave
  primaria hacía fallar el primer insert **en la tabla de hechos de la app**, lejos de Grain.

## Limitaciones vigentes (están en el README)

Solo Postgres (15+ si alguna dimensión es nulable). Solo medidas aditivas — sin conteos distintos
ni percentiles (necesitan HyperLogLog / t-digest, y son **Grain Pro**). Solo grano diario. Un
hecho por rollup, sin rollups sobre rollups (Pro). Sin deltas. `pause:` es espera fija, no
throttling adaptativo por lag de replicación. Un rollup con modelo roto se salta con advertencia.

## Lo que sigue

1. ~~Bloque de estado del README, descripción del gemspec, CHANGELOG, versión~~ — **hecho**. Falta
   `git push`, `gem push grain-0.0.2.gem` y el tag `v0.0.2`. Ojo con el tag: **`v0.0.1` quedó en un
   commit donde `version.rb` todavía decía 0.0.0**, así que no marca lo que se publicó. Poner
   `v0.0.2` en el commit del bump, no antes.
2. 0.0.2 lleva **tres cambios incompatibles**: tenant obligatorio en las lecturas, alias de joins
   `g_<camino>` en vez de `j0`, y triggers nuevos en las tablas que leen las medidas (hay que
   regenerar las migraciones de tabla). Están en el CHANGELOG con su sección de Upgrading. Ni
   golbet ni ekklesia se rompen: las dos corren verdes contra 0.0.2.
3. El artículo fundacional: *"Cómo matamos nuestras vistas materializadas"*, con los números de
   golbet. Según `../proyecto-grain.md` es todo el mercadeo del primer año.
4. **Las 5-10 conversaciones con equipos Rails que tengan dashboards pesados.** Sigue sin hacerse,
   y es el criterio de muerte escrito en frío: si nadie reconoce el problema como serio, no hay
   negocio. El código va muy adelante de la validación.
