/**
 * Modelo de gentrificación: autómata celular + agentes (GAMA 2025.06)
 * Variable independiente: n_amenidades
 * Salidas: índice de gentrificación (% de hogares originales desplazados),
 *          calidad de vida media, tasa anual de desplazamiento y estabilidad.
 *
 * Unidades monetarias: pesos mexicanos constantes de 2024, montos MENSUALES.
 * Al trabajar en términos reales, la inflación general se cancela
 * (ingresos y precios suben juntos); solo se modela el alza REAL de rentas
 * que produce la gentrificación.
 */
model Gentrificacion_Calibrado

global {
    // =========================================================
    // 1. PARÁMETROS EXPERIMENTALES
    // =========================================================
    int n_amenidades <- 4;              // número de equipamientos (máx. 25, uno por manzana)
    float radio_influencia <- 15.0;     // unidades del mundo (1 celda = 2 u, radio = 7.5 celdas)

    // =========================================================
    // 2. CALIBRACIÓN ECONÓMICA (ver tabla de fuentes)
    // =========================================================
    float renta_base_chica <- 7000.0;   // colonia popular ZMG, casa chica
    float mult_departamento <- 0.8;
    float mult_grande <- 1.6;
    float servicios_mensuales <- 1200.0; // luz, agua, gas (supuesto)

    float prob_propietario <- 0.60;
    // Ingreso corriente mensual por decil, Jalisco, ENIGH 2024 (trimestral / 3)
    list<float> ingresos_locales <- [11783.0, 15002.0, 18116.0, 21139.0, 24605.0, 29487.0]; // deciles II a VII (propietarios)
    list<float> ingresos_altos <- [35455.0, 43771.0, 83772.0];                             // deciles VIII a X

    // Equilibrio inicial: cada inquilino original destina entre 25% y 40% de su ingreso a vivienda
    float carga_inicial_min <- 0.25;
    float carga_inicial_max <- 0.40;
    float umbral_carga_desplazamiento <- 0.50; // carga "severa" de vivienda
    float umbral_carga_nuevo_hogar <- 0.40;    // máximo que acepta un hogar que llega
    int tolerancia_meses <- 6;

    // =========================================================
    // 3. MECANISMOS
    // =========================================================
    float intensidad_plusvalia <- 0.08;   // +8% de renta por unidad de cercanía a una amenidad
    float plusvalia_max <- 0.50;          // tope de plusvalía por amenidades
    float beta_contagio <- 1.0;           // renta x2 si toda la vecindad está gentrificada
    float gamma_costo_local <- 0.5;       // encarecimiento del costo de vida local (propietarios)
    float tope_aumento_anual <- 0.10;     // aumento máximo en renovación de contrato
    float prob_ocupacion_mensual <- 0.30; // probabilidad mensual de ocupar una vacante
    float atraccion_base <- 0.05;
    float atraccion_amenidad <- 0.30;
    float atraccion_contagio <- 0.50;
    float movilidad_natural_anual <- 0.03; // mudanzas por motivos ajenos al costo
    float tasa_venta <- 0.01;              // venta por presión de precios (propietarios)
    float peso_acceso_cv <- 0.5;           // peso del acceso a amenidades en la calidad de vida
    float beneficio_contagio_cv <- 0.0;    // 0 = la gentrificación NO mejora la CV por sí misma

    // =========================================================
    // 4. CRITERIO DE ESTABILIDAD Y HORIZONTE
    // =========================================================
    float umbral_estabilidad_anual <- 0.01; // <= 1% de la población original por año
    int meses_estabilidad <- 36;            // 3 años seguidos bajo el umbral
    int horizonte_meses <- 360;             // tope de corrida: 30 años

    // =========================================================
    // 5. ESTADO Y CONTADORES
    // =========================================================
    float step <- 1 #month;
    geometry shape <- envelope(100);
    float prob_movilidad_mensual <- 1 - (1 - movilidad_natural_anual) ^ (1 / 12);

    int poblacion_original_inicial <- 0;
    int desplazados_costo <- 0;
    int desplazados_venta <- 0;
    int salidas_naturales <- 0;
    list<int> historial_desplazados <- [];
    float tasa_desplazamiento_anual <- 0.0;
    int racha_estable <- 0;
    int mes_estable <- -1;
    int mes_5 <- -1;
    int mes_25 <- -1;
    int mes_50 <- -1;

    int desplazados_total -> desplazados_costo + desplazados_venta;
    float indice_gentrificacion -> (poblacion_original_inicial = 0) ? 0.0 : desplazados_total / poblacion_original_inicial;
    float cv_media_originales -> empty(hogar_local where each.es_original) ? 0.0 : mean((hogar_local where each.es_original) collect each.calidad_vida);
    float indice_compuesto -> (cv_media_originales / 100.0) * (1 - indice_gentrificacion);
    bool estabilizado -> racha_estable >= meses_estabilidad;

    // =========================================================
    // 6. INICIALIZACIÓN
    // =========================================================
    init {
        prob_movilidad_mensual <- 1 - (1 - movilidad_natural_anual) ^ (1 / 12);
        do layout_manzanas_aleatorias;
        do colocar_amenidades;

        ask lote_urbano {
            do calcular_score;
        }
        ask lote_urbano where (each.es_origen_propiedad and each.capacidad_hogares > 0) {
            do actualizar_renta_mercado;
        }

        ask lote_urbano where (each.es_origen_propiedad and each.capacidad_hogares > 0) {
            loop times: capacidad_hogares {
                create hogar_local {
                    mi_lote <- myself;
                    location <- myself.location;
                    es_original <- true;
                    es_propietario <- flip(prob_propietario);
                    // La colonia parte en equilibrio SIN amenidades: las amenidades son la intervención.
                    renta_inicial_zona <- myself.renta_base;
                    if (es_propietario) {
                        ingreso_mensual <- one_of(ingresos_locales) * rnd(0.85, 1.15);
                    } else {
                        // Equilibrio inicial: el hogar vive donde puede pagar (renta previa a la intervención)
                        renta_actual <- myself.renta_base;
                        ingreso_mensual <- (renta_actual + servicios_mensuales) / rnd(carga_inicial_min, carga_inicial_max);
                    }
                }
                ocupantes <- ocupantes + 1;
            }
        }
        poblacion_original_inicial <- length(hogar_local);
    }

    action layout_manzanas_aleatorias {
        loop mx from: 0 to: 4 {
            loop my from: 0 to: 4 {
                int ox <- mx * 10;
                int oy <- my * 10;
                list<lote_urbano> celdas_manzana <- lote_urbano where (
                    each.grid_x >= ox and each.grid_x < ox + 10 and
                    each.grid_y >= oy and each.grid_y < oy + 10
                );

                loop times: rnd(1, 3) {
                    int rx <- ox + rnd(0, 8);
                    int ry <- oy + rnd(0, 8);
                    list<lote_urbano> celdas_2x2 <- celdas_manzana where (
                        each.grid_x >= rx and each.grid_x <= rx + 1 and
                        each.grid_y >= ry and each.grid_y <= ry + 1 and
                        each.tipo_vivienda = "vacio"
                    );
                    if (length(celdas_2x2) = 4) {
                        lote_urbano celda_maestra <- celdas_2x2[0];
                        ask celdas_2x2 {
                            tipo_vivienda <- "grande";
                            propiedad_padre <- celda_maestra;
                            es_origen_propiedad <- (self = celda_maestra);
                            capacidad_hogares <- es_origen_propiedad ? 1 : 0;
                            color <- #steelblue;
                        }
                    }
                }

                loop times: rnd(1, 3) {
                    list<lote_urbano> libres <- celdas_manzana where (each.tipo_vivienda = "vacio");
                    if (!empty(libres)) {
                        ask one_of(libres) {
                            tipo_vivienda <- "departamento";
                            capacidad_hogares <- 4;
                            es_origen_propiedad <- true;
                            color <- #purple;
                        }
                    }
                }

                loop times: rnd(2, 5) {
                    list<lote_urbano> libres <- celdas_manzana where (each.tipo_vivienda = "vacio");
                    if (!empty(libres)) {
                        ask one_of(libres) {
                            tipo_vivienda <- "jardin";
                            capacidad_hogares <- 0;
                            color <- #darkolivegreen;
                        }
                    }
                }

                ask celdas_manzana where (each.tipo_vivienda = "vacio") {
                    tipo_vivienda <- "chica";
                    capacidad_hogares <- 1;
                    es_origen_propiedad <- true;
                    color <- #lightskyblue;
                }
            }
        }
    }

    // Una amenidad (lote 2x2) por manzana distinta, en el centro de la manzana
    action colocar_amenidades {
        list<point> manzanas <- [];
        loop mx from: 0 to: 4 {
            loop my from: 0 to: 4 {
                manzanas <- manzanas + {mx * 10, my * 10};
            }
        }
        manzanas <- shuffle(manzanas);
        int n <- min(n_amenidades, 25);
        loop i from: 0 to: n - 1 {
            if (i >= 0 and n > 0) {
                int mx <- int(manzanas[i].x);
                int my <- int(manzanas[i].y);
                list<lote_urbano> lote_infra <- lote_urbano where (
                    each.grid_x >= mx + 4 and each.grid_x <= mx + 5 and
                    each.grid_y >= my + 4 and each.grid_y <= my + 5
                );
                ask lote_infra {
                    tipo_vivienda <- "infraestructura";
                    capacidad_hogares <- 0;
                    es_origen_propiedad <- false;
                    color <- #orange;
                }
                create infraestructura_macro {
                    location <- mean(lote_infra collect each.location);
                }
            }
        }
    }

    // =========================================================
    // 7. DINÁMICA GLOBAL
    // =========================================================
    reflex ocupar_vacantes {
        ask lote_urbano where (each.es_origen_propiedad and each.ocupantes < each.capacidad_hogares) {
            loop times: capacidad_hogares - ocupantes {
                if (flip(prob_ocupacion_mensual)) {
                    float p_alto <- min(0.95, atraccion_base + atraccion_amenidad * acceso + atraccion_contagio * frac_gent_vecindad);
                    bool entra_alto <- flip(p_alto);
                    if (!entra_alto) {
                        // Hogar local con el mismo perfil de ingreso que habitaba este tipo de vivienda
                        float ingreso_local <- (renta_base + servicios_mensuales) / rnd(carga_inicial_min, carga_inicial_max);
                        if ((renta_mercado + servicios_mensuales) / ingreso_local <= umbral_carga_nuevo_hogar) {
                            create hogar_local {
                                mi_lote <- myself;
                                location <- myself.location;
                                es_original <- false;
                                es_propietario <- false;
                                ingreso_mensual <- ingreso_local;
                                renta_actual <- myself.renta_mercado;
                                inicio_contrato <- cycle;
                                renta_inicial_zona <- myself.renta_base;
                            }
                            ocupantes <- ocupantes + 1;
                        } else {
                            entra_alto <- true; // exclusión: la vivienda ya no es accesible para un hogar local
                        }
                    }
                    if (entra_alto) {
                        float ingreso_alto <- one_of(ingresos_altos) * rnd(0.85, 1.15);
                        if ((renta_mercado + servicios_mensuales) / ingreso_alto <= umbral_carga_nuevo_hogar) {
                            create gentrificador {
                                mi_lote <- myself;
                                location <- myself.location;
                                ingreso_mensual <- ingreso_alto;
                            }
                            ocupantes <- ocupantes + 1;
                            gentrificadores_en_lote <- gentrificadores_en_lote + 1;
                        }
                    }
                }
            }
        }
    }

    reflex estadisticas {
        historial_desplazados <- historial_desplazados + desplazados_total;
        int n <- length(historial_desplazados);
        if (n > 12 and poblacion_original_inicial > 0) {
            tasa_desplazamiento_anual <- (historial_desplazados[n - 1] - historial_desplazados[n - 13]) / poblacion_original_inicial;
            if (tasa_desplazamiento_anual <= umbral_estabilidad_anual) {
                racha_estable <- racha_estable + 1;
            } else {
                racha_estable <- 0;
                mes_estable <- -1;
            }
            if (racha_estable >= meses_estabilidad and mes_estable = -1) {
                mes_estable <- cycle - meses_estabilidad + 1;
            }
        }
        if (mes_5 = -1 and indice_gentrificacion >= 0.05) { mes_5 <- cycle; }
        if (mes_25 = -1 and indice_gentrificacion >= 0.25) { mes_25 <- cycle; }
        if (mes_50 = -1 and indice_gentrificacion >= 0.50) { mes_50 <- cycle; }
    }
}

// =========================================================
// CAPA CELULAR
// =========================================================
grid lote_urbano width: 50 height: 50 neighbors: 8 {
    string tipo_vivienda <- "vacio";
    int capacidad_hogares <- 0;
    int ocupantes <- 0;
    int gentrificadores_en_lote <- 0;
    lote_urbano propiedad_padre <- self;
    bool es_origen_propiedad <- false;

    float score_amenidad <- 0.0;   // suma de cercanías (0 a 1 por amenidad)
    float acceso <- 0.0;           // 1 - exp(-score): rendimientos decrecientes
    float plusvalia <- 0.0;
    float renta_base <- 0.0;
    float renta_mercado <- 0.0;
    float frac_gent_vecindad <- 0.0;
    list<lote_urbano> vecinos_residenciales <- [];

    float frac_gentrificada -> (capacidad_hogares = 0) ? 0.0 : gentrificadores_en_lote / capacidad_hogares;

    init {
        color <- #lightskyblue;
    }

    action calcular_score {
        score_amenidad <- 0.0;
        loop a over: infraestructura_macro {
            float d <- location distance_to a.location;
            score_amenidad <- score_amenidad + max(0.0, 1 - d / radio_influencia);
        }
        acceso <- 1 - exp(-score_amenidad);
        plusvalia <- min(plusvalia_max, intensidad_plusvalia * score_amenidad);
        renta_base <- renta_base_chica * ((tipo_vivienda = "grande") ? mult_grande : ((tipo_vivienda = "departamento") ? mult_departamento : 1.0));
        // Vecindad de Moore resuelta a propiedades (una casa grande 2x2 cuenta una vez)
        vecinos_residenciales <- remove_duplicates((neighbors collect each.propiedad_padre) where (each.capacidad_hogares > 0 and each != self));
    }

    action actualizar_renta_mercado {
        frac_gent_vecindad <- empty(vecinos_residenciales) ? 0.0 : mean(vecinos_residenciales collect each.frac_gentrificada);
        renta_mercado <- renta_base * (1 + plusvalia) * (1 + beta_contagio * frac_gent_vecindad);
    }

    // Contagio vecinal: la renta converge a un valor acotado, no se acumula sin límite
    reflex contagio_vecinal when: es_origen_propiedad and capacidad_hogares > 0 {
        do actualizar_renta_mercado;
    }
}

// =========================================================
// AGENTES
// =========================================================
species hogar_local {
    lote_urbano mi_lote;
    bool es_original <- false;
    bool es_propietario <- false;
    float ingreso_mensual;
    float renta_actual <- 0.0;
    float renta_inicial_zona <- 0.0;
    int inicio_contrato <- 0;
    int meses_fallidos <- 0;

    float costo_vivienda -> es_propietario
        ? servicios_mensuales * (1 + gamma_costo_local * mi_lote.frac_gent_vecindad)
        : renta_actual + servicios_mensuales;
    float carga -> costo_vivienda / ingreso_mensual;
    float calidad_vida -> 100 * min(1.0,
        peso_acceso_cv * mi_lote.acceso
        + (1 - peso_acceso_cv) * (1 - min(1.0, carga / umbral_carga_desplazamiento))
        + beneficio_contagio_cv * mi_lote.frac_gent_vecindad);

    aspect base {
        draw circle(0.4) color: es_original ? (es_propietario ? #darkblue : #dodgerblue) : #gray border: #white;
    }

    action salir (string motivo) {
        mi_lote.ocupantes <- mi_lote.ocupantes - 1;
        if (motivo = "costo" and es_original) { desplazados_costo <- desplazados_costo + 1; }
        if (motivo = "venta" and es_original) { desplazados_venta <- desplazados_venta + 1; }
        if (motivo = "natural") { salidas_naturales <- salidas_naturales + 1; }
        do die;
    }

    reflex movilidad_natural when: flip(prob_movilidad_mensual) {
        do salir("natural");
    }

    reflex renovar_contrato when: !es_propietario and cycle > inicio_contrato and (cycle - inicio_contrato) mod 12 = 0 {
        renta_actual <- min(max(renta_actual, mi_lote.renta_mercado), renta_actual * (1 + tope_aumento_anual));
    }

    reflex vender when: es_propietario and flip(tasa_venta * max(0.0, mi_lote.renta_mercado / renta_inicial_zona - 1)) {
        do salir("venta");
    }

    reflex revisar_finanzas {
        if (carga > umbral_carga_desplazamiento) { meses_fallidos <- meses_fallidos + 1; }
        else { meses_fallidos <- 0; }
        if (meses_fallidos >= tolerancia_meses) {
            do salir("costo");
        }
    }
}

species gentrificador {
    lote_urbano mi_lote;
    float ingreso_mensual;

    aspect base {
        draw circle(0.4) color: #crimson border: #white;
    }

    reflex movilidad_natural when: flip(prob_movilidad_mensual) {
        mi_lote.ocupantes <- mi_lote.ocupantes - 1;
        mi_lote.gentrificadores_en_lote <- mi_lote.gentrificadores_en_lote - 1;
        do die;
    }
}

species infraestructura_macro {
    aspect base { }
}

// =========================================================
// EXPERIMENTOS
// =========================================================
experiment "Simulacion" type: gui {
    parameter "Número de amenidades" var: n_amenidades min: 0 max: 25 category: "Experimento";
    parameter "Radio de influencia" var: radio_influencia category: "Experimento";
    parameter "Beta contagio" var: beta_contagio category: "Mecanismos";
    parameter "Atracción por amenidad" var: atraccion_amenidad category: "Mecanismos";
    parameter "Tasa de venta" var: tasa_venta category: "Mecanismos";
    parameter "Beneficio de gentrificación en CV" var: beneficio_contagio_cv category: "Mecanismos";

    reflex fin when: cycle >= horizonte_meses {
        ask simulation { do pause; }
    }

    output {
        display "Mapa de la Colonia" type: 2d {
            grid lote_urbano border: #black;
            species infraestructura_macro aspect: base;
            species hogar_local aspect: base;
            species gentrificador aspect: base;
            graphics "Calles" {
                loop i from: 0 to: 5 {
                    float pos <- i * 20.0;
                    draw line([{0, pos}, {100, pos}]) color: #black width: 4;
                    draw line([{pos, 0}, {pos, 100}]) color: #black width: 4;
                }
            }
        }
        display "Impacto Social" type: 2d {
            chart "Desplazamiento y calidad de vida" type: series x_label: "Meses" {
                data "Índice de gentrificación (%)" value: indice_gentrificacion * 100 color: #red marker: false;
                data "Calidad de vida media originales" value: cv_media_originales color: #green marker: false;
                data "Tasa anual de desplazamiento (%)" value: tasa_desplazamiento_anual * 100 color: #orange marker: false;
                data "Umbral de estabilidad (1%)" value: umbral_estabilidad_anual * 100 color: #gray marker: false;
            }
        }
        monitor "Índice de gentrificación" value: indice_gentrificacion;
        monitor "CV media (originales)" value: cv_media_originales;
        monitor "Índice compuesto" value: indice_compuesto;
        monitor "Mes de estabilización" value: mes_estable;
    }
}

// Barrido: 10 niveles de amenidades x 10 réplicas = 100 simulaciones de 30 años
experiment "Barrido amenidades" type: batch repeat: 10 keep_seed: false until: cycle >= horizonte_meses {
    parameter "Número de amenidades" var: n_amenidades among: [0, 1, 2, 4, 6, 8, 12, 16, 20, 25];
    method exploration;

    reflex guardar {
        ask simulations {
            save [n_amenidades, seed, poblacion_original_inicial, desplazados_costo, desplazados_venta,
                  indice_gentrificacion, cv_media_originales, indice_compuesto, tasa_desplazamiento_anual,
                  estabilizado, mes_estable, mes_5, mes_25, mes_50, length(gentrificador)]
                to: "resultados_barrido.csv" format: "csv" rewrite: false header: true;
        }
    }
}
