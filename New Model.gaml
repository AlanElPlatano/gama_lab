model Gentrificacion_Jardines_Variado

global {
    // ==========================================
    // 1. VARIABLES GLOBALES
    // ==========================================
    float inflacion_mensual <- 0.000;
    float costo_servicios_global <- 4000.0;
    int habitantes_desplazados <- 0;
    float step <- 1 #month;

    geometry shape <- envelope(100); 

    // ==========================================
    // 2. INICIALIZACIÓN (init)
    // ==========================================
    init {
    // 1. Generar layout de manzanas
    do layout_manzanas_aleatorias;

    // 2. Crear Infraestructura en un lote 2x2 real del grid (sin invadir calles)
    loop times: 2 {
        // Elegir una esquina de manzana aleatoria para colocar un equipamiento (2x2)
        int mx <- rnd(0, 4) * 10;
        int my <- rnd(0, 4) * 10;
        
        list<lote_urbano> lote_infra <- lote_urbano where (
            each.grid_x >= mx + 4 and each.grid_x <= mx + 5 and
            each.grid_y >= my + 4 and each.grid_y <= my + 5
        );
        
        if (!empty(lote_infra)) {
            // Convertir esas celdas en Equipamiento Urbano
            ask lote_infra {
                tipo_vivienda <- "infraestructura";
                capacidad_hogares <- 0;
                color <- #orange;
            }
            
            // Crear el agente que emite la plusvalía centrado ahí
            create infraestructura_macro {
                location <- lote_infra[0].location;
                radio_influencia <- 15.0;
            }
        }
    }

    // 3. Poblar habitantes (se salta las celdas de infraestructura automáticamente)
    ask lote_urbano where (each.es_origen_propiedad and each.capacidad_hogares > 0) {
        loop times: capacidad_hogares {
            create habitante_original {
                mi_lote <- myself;
                location <- myself.location;
                es_propietario <- flip(0.60); 
                ingreso_mensual <- 18000.0 + rnd(8000.0);
                myself.inquilinos_actuales <- myself.inquilinos_actuales + 1;
            }
        }
    }
}

    // ==========================================
    // 3. LAYOUT ALEATORIO POR MANZANA
    // ==========================================
    action layout_manzanas_aleatorias {
        loop mx from: 0 to: 4 {
            loop my from: 0 to: 4 {
                int ox <- mx * 10;
                int oy <- my * 10;
                
                // Celdas pertenecientes a esta manzana de 10x10
                list<lote_urbano> celdas_manzana <- lote_urbano where (
                    each.grid_x >= ox and each.grid_x < ox + 10 and
                    each.grid_y >= oy and each.grid_y < oy + 10
                );

                // 1. Intentar colocar Casas Grandes (2x2) en posiciones aleatorias
                int casas_grandes_deseadas <- rnd(1, 3);
                loop times: casas_grandes_deseadas {
                    int rx <- ox + rnd(0, 8);
                    int ry <- oy + rnd(0, 8);
                    
                    list<lote_urbano> celdas_2x2 <- celdas_manzana where (
                        each.grid_x >= rx and each.grid_x <= rx + 1 and
                        each.grid_y >= ry and each.grid_y <= ry + 1 and
                        each.tipo_vivienda = "vacio"
                    );

                    // Solo si el bloque 2x2 está completamente libre
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

                // 2. Departamentos (morados, 4 familias) de forma aleatoria (1 a 3 por manzana)
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

                // 3. Jardines / Patios (verdes) de forma aleatoria (2 a 5 por manzana)
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

                // 4. El resto de las celdas vacías se vuelven Casas Chicas (1x1)
                ask celdas_manzana where (each.tipo_vivienda = "vacio") {
                    tipo_vivienda <- "chica";
                    capacidad_hogares <- 1;
                    es_origen_propiedad <- true;
                    color <- #lightskyblue;
                }
            }
        }
    }

    reflex inflacion_ciudad {
        costo_servicios_global <- costo_servicios_global * (1 + inflacion_mensual);
    }
    
    // Spawner de Gentrificadores
    reflex llegada_foraneos when: flip(0.4) {
        list<lote_urbano> lotes_disponibles <- lote_urbano where (each.es_origen_propiedad and each.inquilinos_actuales < each.capacidad_hogares);
        
        if (!empty(lotes_disponibles)) {
            create gentrificador number: 1 {
                ingreso_mensual <- 35000.0 + rnd(15000.0);
                mi_lote <- one_of(lotes_disponibles);
                location <- mi_lote.location;
                mi_lote.inquilinos_actuales <- mi_lote.inquilinos_actuales + 1;
                mi_lote.uso_suelo <- 1; // Gentrificado / Comercial
            }
        }
    }
}

// ==========================================
// CAPA CELULAR (Grid con Bordes)
// ==========================================
grid lote_urbano width: 50 height: 50 neighbors: 8 {
    string tipo_vivienda <- "vacio"; 
    int capacidad_hogares <- 0;
    int inquilinos_actuales <- 0;
    
    lote_urbano propiedad_padre <- self;
    bool es_origen_propiedad <- false;

    float renta_base <- 8500.0;
    float sobrecosto_gentrificacion <- 0.0; 
    int uso_suelo <- 0; 
    float plusvalia_radial <- 0.0;
    
    init {
        color <- #lightskyblue;
    }

    reflex calcular_plusvalia when: cycle = 0 {
        if (tipo_vivienda != "jardin") {
            loop infra over: infraestructura_macro {
                float dist <- self distance_to infra;
                if (dist <= infra.radio_influencia) {
                    plusvalia_radial <- plusvalia_radial + (500.0 / max(1.0, dist)); 
                }
            }
            renta_base <- renta_base + plusvalia_radial;
        }
    }

    reflex contagio_vecinal when: tipo_vivienda != "jardin" and (cycle > 0) {
        int vecinos_gentrificados <- (neighbors count (each.uso_suelo = 1));
        if (vecinos_gentrificados > 0) {
            sobrecosto_gentrificacion <- sobrecosto_gentrificacion + (renta_base * 0.02 * vecinos_gentrificados);
        }
    }
}

// ==========================================
// ESPECIES DE AGENTES
// ==========================================
species habitante_original {
    lote_urbano mi_lote;
    bool es_propietario;
    float ingreso_mensual;
    int meses_fallidos <- 0;
    int tolerancia_meses <- 3;

    float calidad_vida_percibida -> min(100.0, 50.0 + (mi_lote.plusvalia_radial * 0.02) + ((mi_lote.neighbors count (each.uso_suelo = 1)) * 5.0));

    aspect base {
        draw circle(0.4) color: es_propietario ? #darkblue : #dodgerblue border: #white;
    }

    reflex revisar_finanzas {
        float multiplicador_tamano <- (mi_lote.tipo_vivienda = "grande") ? 1.5 : ((mi_lote.tipo_vivienda = "departamento") ? 0.8 : 1.0);
        float renta_actual <- (mi_lote.renta_base + mi_lote.sobrecosto_gentrificacion) * multiplicador_tamano;
        float costo_vida_actual <- costo_servicios_global + (mi_lote.sobrecosto_gentrificacion * 0.5); 
        
        bool no_puede_pagar <- false;

        if (!es_propietario) {
            if ((renta_actual + costo_vida_actual) > (ingreso_mensual * 0.35)) { no_puede_pagar <- true; }
        } else {
            if (costo_vida_actual > (ingreso_mensual * 0.45)) { no_puede_pagar <- true; }
        }

        if (no_puede_pagar) { meses_fallidos <- meses_fallidos + 1; } 
        else { meses_fallidos <- 0; }

        if (meses_fallidos >= tolerancia_meses) {
            mi_lote.inquilinos_actuales <- mi_lote.inquilinos_actuales - 1;
            habitantes_desplazados <- habitantes_desplazados + 1;
            do die;
        }
    }
}

species gentrificador {
    lote_urbano mi_lote <- nil;
    float ingreso_mensual;

    aspect base {
        if (mi_lote != nil) {
            draw circle(0.4) color: #crimson border: #white;
        }
    }
}

species infraestructura_macro {
    float radio_influencia;
    // Ya no dibuja un square(3) flotante; la celda del grid ya tiene el color amarillo/naranja
    aspect base { } 
}

// ==========================================
// INTERFAZ GRÁFICA
// ==========================================
experiment "Simulacion Jardines Variado" type: gui {
    output {
        display "Mapa de la Colonia" refresh: every(1#cycles) {
            grid lote_urbano border: #black; 
            
            species infraestructura_macro aspect: base;
            species habitante_original aspect: base;
            species gentrificador aspect: base;

            graphics "Calles Estéticas" {
                loop i from: 0 to: 5 {
                    float pos <- i * (100.0 / 5.0); 
                    draw line([{0, pos}, {100, pos}]) color: #black width: 4;
                    draw line([{pos, 0}, {pos, 100}]) color: #black width: 4;
                }
            }
        }

        display "Impacto Social (2D)" refresh: every(1#cycles) {
            chart "Desplazamiento vs Costo de Vida" type: series background: #white x_label: "Meses transcurridos" {
                data "Habitantes Desplazados" value: habitantes_desplazados color: #red marker: false;
                data "Costo de Vida Global ($)" value: costo_servicios_global color: #orange marker: false;
            }
        }
    }
}