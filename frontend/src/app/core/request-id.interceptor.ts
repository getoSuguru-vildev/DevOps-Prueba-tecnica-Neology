import { HttpInterceptorFn } from '@angular/common/http';

export const REQUEST_ID_HEADER = 'X-Request-ID';

// Cada llamada a la API lleva un id único. nginx y el backend lo escriben en sus logs,
// así una petición se puede seguir desde el navegador hasta la base de datos.
export const requestIdInterceptor: HttpInterceptorFn = (req, next) => {
  if (req.headers.has(REQUEST_ID_HEADER)) {
    return next(req);
  }
  return next(req.clone({ setHeaders: { [REQUEST_ID_HEADER]: newRequestId() } }));
};

// crypto.randomUUID solo existe en contextos seguros (https o localhost);
// getRandomValues funciona también por http, por ejemplo en dev sin certificado.
function newRequestId(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}
