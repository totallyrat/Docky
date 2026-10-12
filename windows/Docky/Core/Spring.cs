using System;

namespace Docky.Core
{
    /// <summary>
    /// A damped spring, parameterised like SwiftUI's (response, dampingFraction) so the island
    /// moves exactly like the Mac version.
    /// </summary>
    public sealed class Spring
    {
        public double Value;
        public double Velocity;
        public double Target;
        public double Response = 0.5;
        public double Damping = 0.8;

        public Spring(double value) { Value = value; Target = value; }

        public bool IsSettled => Math.Abs(Value - Target) < 0.05 && Math.Abs(Velocity) < 0.05;

        public void Snap(double value) { Value = Target = value; Velocity = 0; }

        public void Step(double dt)
        {
            if (IsSettled) { Value = Target; Velocity = 0; return; }
            double k = Math.Pow(2 * Math.PI / Math.Max(0.05, Response), 2);
            double c = 4 * Math.PI * Damping / Math.Max(0.05, Response);
            // Sub-step for stability at low frame rates.
            int steps = Math.Max(1, (int)Math.Ceiling(dt / 0.004));
            double h = dt / steps;
            for (int i = 0; i < steps; i++)
            {
                double force = -k * (Value - Target) - c * Velocity;
                Velocity += force * h;
                Value += Velocity * h;
            }
        }
    }
}
