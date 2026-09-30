package mx.neology.parking.config;

import static net.logstash.logback.argument.StructuredArguments.v;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.UUID;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Toma el X-Request-ID que manda el frontend (o nginx), o genera uno si no viene o no es válido.
 * Lo deja en el MDC para que salga en todos los logs de la petición, lo regresa en la respuesta
 * y registra una línea por petición con método, ruta, status y duración.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class CorrelationIdFilter extends OncePerRequestFilter {

    public static final String HEADER = "X-Request-ID";
    public static final String MDC_KEY = "requestId";

    // Solo caracteres seguros: evita que alguien meta saltos de línea o basura en los logs.
    private static final Pattern VALID_ID = Pattern.compile("^[A-Za-z0-9._-]{1,64}$");
    private static final Logger log = LoggerFactory.getLogger(CorrelationIdFilter.class);

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String requestId = resolveRequestId(request.getHeader(HEADER));
        MDC.put(MDC_KEY, requestId);
        response.setHeader(HEADER, requestId);
        long start = System.nanoTime();
        int status = HttpServletResponse.SC_INTERNAL_SERVER_ERROR;
        try {
            chain.doFilter(request, response);
            status = response.getStatus();
        } finally {
            // Los health checks llegan cada pocos segundos; no aportan en el log de peticiones.
            if (!request.getRequestURI().startsWith("/actuator")) {
                long durationMs = (System.nanoTime() - start) / 1_000_000;
                log.info("{} {} status={} duration_ms={}",
                        v("method", request.getMethod()),
                        v("path", request.getRequestURI()),
                        v("status", status),
                        v("duration_ms", durationMs));
            }
            MDC.remove(MDC_KEY);
        }
    }

    static String resolveRequestId(String incoming) {
        if (incoming != null && VALID_ID.matcher(incoming).matches()) {
            return incoming;
        }
        return UUID.randomUUID().toString();
    }
}
