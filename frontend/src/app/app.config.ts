import { LOCALE_ID, ApplicationConfig } from '@angular/core';
import { provideAnimationsAsync } from '@angular/platform-browser/animations/async';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { provideRouter } from '@angular/router';
import { routes } from './app.routes';
import { requestIdInterceptor } from './core/request-id.interceptor';

export const appConfig: ApplicationConfig = {
  providers: [
    provideRouter(routes),
    provideHttpClient(withInterceptors([requestIdInterceptor])),
    provideAnimationsAsync(),
    { provide: LOCALE_ID, useValue: 'es-MX' }
  ]
};

