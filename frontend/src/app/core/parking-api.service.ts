import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable, catchError, throwError } from 'rxjs';
import {
  ApiError,
  MessageResponse,
  Movement,
  ResidentPayment,
  Vehicle,
  VehicleDetail,
  VehicleType
} from './models';
import { REQUEST_ID_HEADER } from './request-id.interceptor';

@Injectable({ providedIn: 'root' })
export class ParkingApiService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = '/neo';

  listVehicles(): Observable<Vehicle[]> {
    return this.http.get<Vehicle[]>(`${this.baseUrl}/vehiculos`).pipe(catchError(this.handleError));
  }

  getVehicle(plate: string): Observable<VehicleDetail> {
    return this.http.get<VehicleDetail>(`${this.baseUrl}/vehiculos/${encodeURIComponent(plate)}`)
      .pipe(catchError(this.handleError));
  }

  createVehicle(plate: string, type: VehicleType): Observable<Vehicle> {
    const pathByType: Record<VehicleType, string> = {
      OFICIAL: 'oficiales',
      RESIDENTE: 'residentes',
      NO_RESIDENTE: 'no-residentes'
    };
    return this.http.post<Vehicle>(`${this.baseUrl}/vehiculos/${pathByType[type]}`, { placa: plate })
      .pipe(catchError(this.handleError));
  }

  registerEntry(plate: string): Observable<Movement> {
    return this.http.post<Movement>(`${this.baseUrl}/estancias/entrada`, { placa: plate })
      .pipe(catchError(this.handleError));
  }

  registerExit(plate: string): Observable<Movement> {
    return this.http.post<Movement>(`${this.baseUrl}/estancias/salida`, { placa: plate })
      .pipe(catchError(this.handleError));
  }

  residentPayments(): Observable<ResidentPayment[]> {
    return this.http.get<ResidentPayment[]>(`${this.baseUrl}/residentes/pagos`)
      .pipe(catchError(this.handleError));
  }

  startNewMonth(): Observable<MessageResponse> {
    return this.http.post<MessageResponse>(`${this.baseUrl}/mes/iniciar`, {})
      .pipe(catchError(this.handleError));
  }

  private readonly handleError = (response: HttpErrorResponse): Observable<never> => {
    const body = response.error as ApiError | undefined;
    const fieldMessages = body?.campos ? Object.values(body.campos).join('. ') : '';
    const message = fieldMessages || body?.mensaje || 'No fue posible comunicarse con el servidor';
    // En errores del servidor se muestra el id de la petición para que soporte la encuentre en los logs.
    const requestId = response.headers?.get(REQUEST_ID_HEADER);
    const withReference = response.status >= 500 && requestId ? `${message} (referencia: ${requestId})` : message;
    return throwError(() => new Error(withReference));
  };
}

